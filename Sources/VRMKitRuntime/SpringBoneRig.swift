import Foundation
import simd
import VRMKit

/// The colliders of one group, each a shape in the space of the node it hangs off.
/// VRM 0.x hangs a whole group off one node; VRM 1.0 gives every collider its own.
package struct SpringBoneRigColliderGroup<Node: VRMRuntimeNode> {
    let colliders: [(node: Node, shape: SpringBoneColliderShape)]

    package init(colliders: [(node: Node, shape: SpringBoneColliderShape)]) {
        self.colliders = colliders
    }
}

/// The fixed step the spring bones swing in.
package enum SpringBoneSimulation {
    /// A fixed rate keeps the swing the same at every display refresh rate.
    package static let step: TimeInterval = 1.0 / 60.0
    /// Time past these steps is dropped, so a long hitch stalls the swing rather than
    /// replaying it.
    package static let maximumStepsPerUpdate = 4
}

/// How a ``SpringBoneRig`` swings.
public struct SpringBoneConfiguration: Sendable {
    /// A world-space force added to every joint, scaled like gravity: wind.
    public var externalForce: SIMD3<Float>

    public init(externalForce: SIMD3<Float> = .zero) {
        self.externalForce = externalForce
    }
}

/// Every spring of one model, and the per-frame solve that swings them.
///
/// ``VRMRuntimeNode`` names the only renderer-specific part, reading a node's
/// transform and writing its rotation.
package final class SpringBoneRig<Node: VRMRuntimeNode> where Node.RuntimeNode == Node {
    /// One node of a spring, ordered parents first so a single pass composes the
    /// whole spring's world transforms.
    private struct Link {
        let node: Node
        /// The link this one hangs off, nil for one whose parent is outside the spring:
        /// its world transform is read from the renderer instead.
        let parent: Int?
        /// Nil for a node a spring only passes through, which VRM 1.0 allows between
        /// two joints of a chain.
        var joint: SpringBoneJoint?
        let setting: SpringBoneJointSetting
    }

    private struct Spring {
        let center: Node?
        /// Indices into the rig's collider table, shared between springs so a collider
        /// every strand of hair names is solved once a frame.
        let colliderIndices: [Int]
        var links: [Link]
    }

    /// One collider of the model. Entries are deduplicated at build time, so a frame
    /// solves each world shape once however many springs keep out of it.
    private struct ColliderEntry {
        let node: Node
        let shape: SpringBoneColliderShape
    }

    package var configuration = SpringBoneConfiguration()

    private var springs: [Spring] = []
    private var colliderEntries: [ColliderEntry] = []
    private var pendingReset = false
    /// Time handed to ``update(deltaTime:)`` and not yet simulated.
    private var accumulator: TimeInterval = 0

    // Held across frames so a solve allocates nothing.
    private var worldColliders: [SpringBoneCollider] = []
    private var springColliders: [SpringBoneCollider] = []
    private var centers: [ObjectIdentifier: SpringBoneCenter] = [:]
    private var worlds: [SpringBoneWorldTransform] = []

    package init() {}

    /// Forgets the motion the springs carry between frames, so the next update starts
    /// them at rest: for teleporting a model without a frame of flung hair.
    package func reset() {
        pendingReset = true
    }

    /// Advances the simulation by `deltaTime`, in fixed steps. Time short of a step
    /// carries to the next update, so the swing does not depend on how often a
    /// renderer draws.
    ///
    /// Returns whether a joint was posed, so a renderer re-skins only the frames a step fell in.
    @discardableResult
    package func update(deltaTime: TimeInterval) -> Bool {
        guard !springs.isEmpty else { return false }
        if pendingReset {
            pendingReset = false
            accumulator = 0
            settle()
            return true
        }
        let step = SpringBoneSimulation.step
        accumulator = min(max(0, accumulator + deltaTime),
                          step * TimeInterval(SpringBoneSimulation.maximumStepsPerUpdate))
        guard accumulator >= step else { return false }

        // The renderer's state stands still within one update, so read it once however
        // many steps the frame takes.
        refreshWorldColliders()
        refreshCenters()
        while accumulator >= step {
            accumulator -= step
            for index in springs.indices {
                self.step(&springs[index], deltaTime: Float(step))
            }
        }
        return true
    }

    private func refreshWorldColliders() {
        worldColliders.removeAll(keepingCapacity: true)
        worldColliders.reserveCapacity(colliderEntries.count)
        for entry in colliderEntries {
            worldColliders.append(entry.shape.world(in: entry.node.worldMatrix))
        }
    }

    private func refreshCenters() {
        centers.removeAll(keepingCapacity: true)
        for spring in springs {
            guard let center = spring.center else { continue }
            let key = ObjectIdentifier(center)
            guard centers[key] == nil else { continue }
            centers[key] = SpringBoneCenter(localToWorld: center.worldMatrix)
        }
    }

    private func step(_ spring: inout Spring, deltaTime: Float) {
        springColliders.removeAll(keepingCapacity: true)
        for index in spring.colliderIndices {
            springColliders.append(worldColliders[index])
        }
        let center = spring.center.map { centers[ObjectIdentifier($0)] } ?? nil

        worlds.removeAll(keepingCapacity: true)
        worlds.reserveCapacity(spring.links.count)

        for index in spring.links.indices {
            let link = spring.links[index]
            // The only world transforms the rig reads rather than composes.
            let parentWorld = link.parent.map { worlds[$0] }
                ?? link.node.runtimeParent?.worldTransform
                ?? .identity
            var world = link.node.worldTransform(under: parentWorld)

            if var joint = link.joint {
                let rotation = joint.update(deltaTime: deltaTime,
                                            setting: link.setting,
                                            head: world.translation,
                                            parentRotation: parentWorld.rotation,
                                            center: center,
                                            colliders: springColliders,
                                            externalForce: configuration.externalForce)
                spring.links[index].joint = joint
                link.node.setLocalRotation(parentWorld.rotation.inverse * rotation)
                // Composed again from the rotation the joint was swung to, which its
                // children hang off.
                world = link.node.worldTransform(under: parentWorld)
            }
            worlds.append(world)
        }
    }

    /// Puts every joint back at rest: the authored rotation, and tails carrying no motion.
    private func settle() {
        refreshCenters()
        for springIndex in springs.indices {
            let center = springs[springIndex].center.map { centers[ObjectIdentifier($0)] } ?? nil
            worlds.removeAll(keepingCapacity: true)
            worlds.reserveCapacity(springs[springIndex].links.count)
            for index in springs[springIndex].links.indices {
                let link = springs[springIndex].links[index]
                let parentWorld = link.parent.map { worlds[$0] }
                    ?? link.node.runtimeParent?.worldTransform
                    ?? .identity
                if var joint = link.joint {
                    link.node.setLocalRotation(joint.restLocalRotation)
                    let world = link.node.worldTransform(under: parentWorld)
                    joint.settle(head: world.translation,
                                 parentRotation: parentWorld.rotation,
                                 center: center)
                    springs[springIndex].links[index].joint = joint
                    worlds.append(world)
                } else {
                    worlds.append(link.node.worldTransform(under: parentWorld))
                }
            }
        }
    }
}

// MARK: - Building

package extension SpringBoneRig {
    /// Every spring the model states, whichever version states them. `node` resolves a
    /// glTF node index to the renderer's node, the only renderer-specific part.
    static func make(vrm: VRM, node: (Int) throws -> Node) throws -> SpringBoneRig<Node> {
        let rig = SpringBoneRig<Node>()
        switch vrm {
        case .v0(let vrm0): try rig.addVRM0Springs(vrm0.secondaryAnimation, node: node)
        case .v1(let vrm1): try rig.addVRM1Springs(vrm1.springBone, node: node)
        }
        return rig
    }

    func addVRM0Springs(_ secondaryAnimation: VRM0.SecondaryAnimation,
                        node: (Int) throws -> Node) throws {
        let allColliderGroups = try secondaryAnimation.colliderGroups.map { group in
            SpringBoneRigColliderGroup(colliders: try group.colliders.map {
                (try node(group.node), try SpringBoneColliderShape(vrm0Collider: $0))
            })
        }
        for boneGroup in secondaryAnimation.boneGroups where !boneGroup.bones.isEmpty {
            // VRM 0.x writes -1 for "no centre", in a field it always writes.
            let center = boneGroup.center >= 0 ? try node(boneGroup.center) : nil
            addVRM0Spring(center: center,
                          rootBones: try boneGroup.bones.map { try node($0) },
                          setting: try SpringBoneJointSetting(vrm0BoneGroup: boneGroup),
                          colliderGroups: try Self.colliderGroups(allColliderGroups, at: boneGroup.colliderGroups))
        }
    }

    func addVRM1Springs(_ springBone: VRM1.SpringBone?, node: (Int) throws -> Node) throws {
        // An unmodeled spec version may shape the data differently, so the model just
        // goes without physics.
        guard let springBone, VRM1.SpringBone.supports(specVersion: springBone.specVersion) else { return }
        let springs = springBone.springs ?? []
        try Self.validateVRM1(springs, node: node)
        let sourceColliders = springBone.colliders ?? []
        let allColliderGroups = try (springBone.colliderGroups ?? []).map { group in
            SpringBoneRigColliderGroup<Node>(colliders: try group.colliders.map { index in
                let collider = try sourceColliders[safe: index]
                    ??? ._dataInconsistent("a collider group names collider \(index), "
                                           + "and the model holds \(sourceColliders.count)")
                return (node: try node(collider.node), shape: try SpringBoneColliderShape(vrm1Collider: collider))
            })
        }
        for spring in springs {
            let jointNodes = try spring.joints.map { try node($0.node) }
            // A chain of one joint is only a tail, so it swings nothing.
            guard jointNodes.count > 1 else { continue }
            try addVRM1Spring(center: try spring.center.map { try node($0) },
                              chain: zip(jointNodes, spring.joints).map {
                                  (node: $0, setting: try SpringBoneJointSetting(vrm1Joint: $1))
                              },
                              colliderGroups: try Self.colliderGroups(allColliderGroups,
                                                                      at: spring.colliderGroups ?? []))
        }
    }

    /// The rules `VRMC_springBone` states across springs, which building one at a time
    /// cannot see.
    private static func validateVRM1(_ springs: [VRM1.SpringBone.Spring],
                                     node: (Int) throws -> Node) throws {
        var springOfJoint: [ObjectIdentifier: Int] = [:]
        for (index, spring) in springs.enumerated() {
            for joint in spring.joints {
                let key = ObjectIdentifier(try node(joint.node))
                guard springOfJoint.updateValue(index, forKey: key) == nil else {
                    throw VRMError._dataInconsistent(
                        "node \(joint.node) is a joint of more than one spring"
                    )
                }
            }
        }
        for (index, spring) in springs.enumerated() {
            guard let centerIndex = spring.center, let first = spring.joints.first else { continue }
            let center = try node(centerIndex)
            guard ancestry(of: try node(first.node)).contains(where: { $0 === center }) else {
                throw VRMError._dataInconsistent(
                    "spring \(index) hangs in node \(centerIndex), which is neither its first joint nor above it"
                )
            }
            for ancestor in ancestry(of: center) {
                guard let other = springOfJoint[ObjectIdentifier(ancestor)], other != index else { continue }
                throw VRMError._dataInconsistent(
                    "spring \(index) hangs in node \(centerIndex), which spring \(other) swings"
                )
            }
        }
    }

    /// A node and every node above it.
    private static func ancestry(of node: Node) -> some Sequence<Node> {
        sequence(first: node) { $0.runtimeParent }
    }

    /// The collider groups a spring names. One naming a group the model does not hold
    /// is refused rather than swung without it.
    private static func colliderGroups(_ groups: [SpringBoneRigColliderGroup<Node>],
                                       at indices: [Int]) throws -> [SpringBoneRigColliderGroup<Node>] {
        try indices.map { index in
            try groups[safe: index]
                ??? ._dataInconsistent("a spring names collider group \(index), "
                                       + "and the model holds \(groups.count)")
        }
    }

    /// A VRM 0.x bone group: every bone below each root swings, on the one setting the
    /// group states, and each root is its own spring.
    func addVRM0Spring(center: Node?,
                       rootBones: [Node],
                       setting: SpringBoneJointSetting,
                       colliderGroups: [SpringBoneRigColliderGroup<Node>]) {
        let centerTransform = center.map { SpringBoneCenter(localToWorld: $0.worldMatrix) }
        let colliderIndices = colliderIndices(for: colliderGroups)
        for root in rootBones {
            var links: [Link] = []
            appendVRM0Links(below: root, parent: nil, setting: setting, center: centerTransform, to: &links)
            append(Spring(center: center, colliderIndices: colliderIndices, links: links))
        }
    }

    /// The rig-level collider entries `groups` name, adding the ones the rig has not
    /// seen. Springs commonly share groups, so an entry is stored, and solved, once.
    private func colliderIndices(for groups: [SpringBoneRigColliderGroup<Node>]) -> [Int] {
        var indices: [Int] = []
        for group in groups {
            for (node, shape) in group.colliders {
                if let existing = colliderEntries.firstIndex(where: { $0.node === node && $0.shape == shape }) {
                    if !indices.contains(existing) { indices.append(existing) }
                } else {
                    colliderEntries.append(ColliderEntry(node: node, shape: shape))
                    indices.append(colliderEntries.count - 1)
                }
            }
        }
        return indices
    }

    /// A VRM 1.0 spring: each consecutive pair of the chain is one joint that swings, so
    /// `a-b-c-d` is `a-b`, `b-c` and `c-d`, and the last is only a tail.
    ///
    /// `VRMC_springBone` has each joint be a descendant of the one before it, so a chain
    /// that is not one descent of the hierarchy is refused.
    func addVRM1Spring(center: Node?,
                       chain: [(node: Node, setting: SpringBoneJointSetting)],
                       colliderGroups: [SpringBoneRigColliderGroup<Node>]) throws {
        guard let first = chain.first?.node else { return }
        let centerTransform = center.map { SpringBoneCenter(localToWorld: $0.worldMatrix) }
        var links: [Link] = []
        var indexOfNode: [ObjectIdentifier: Int] = [:]

        /// The nodes from the spring's first joint down to `node`, both ends included, or
        /// nil for a node that is not below it. Nodes the spec allows between two joints
        /// are composed through even though they do not swing.
        func descent(to node: Node) -> [Node]? {
            var reversed: [Node] = []
            var step: Node? = node
            while let current = step {
                reversed.append(current)
                if current === first { return reversed.reversed() }
                step = current.runtimeParent
            }
            return nil
        }

        func link(_ node: Node, setting: SpringBoneJointSetting, joint: SpringBoneJoint?) throws {
            if let existing = indexOfNode[ObjectIdentifier(node)] {
                if let joint { links[existing].joint = joint }
                return
            }
            let descent = try descent(to: node)
                ??? ._dataInconsistent("a spring states a joint that is not below its first one, "
                                       + "so its joints are not one chain")
            for step in descent where indexOfNode[ObjectIdentifier(step)] == nil {
                links.append(Link(node: step,
                                  parent: step.runtimeParent.flatMap { indexOfNode[ObjectIdentifier($0)] },
                                  joint: step === node ? joint : nil,
                                  setting: setting))
                indexOfNode[ObjectIdentifier(step)] = links.count - 1
            }
        }

        for (head, tail) in zip(chain, chain.dropFirst()) {
            try link(head.node,
                     setting: head.setting,
                     joint: Self.joint(node: head.node,
                                       tail: tail.node.worldPosition,
                                       center: centerTransform))
        }
        append(Spring(center: center, colliderIndices: colliderIndices(for: colliderGroups), links: links))
    }

    /// A spring with nothing to swing is left out rather than solved every frame for nothing.
    private func append(_ spring: Spring) {
        guard spring.links.contains(where: { $0.joint != nil }) else { return }
        springs.append(spring)
    }

    /// VRM 0.x swings every bone below the root: one with children towards the first of
    /// them, and a leaf towards the tail VRM 0.x gives it.
    private func appendVRM0Links(below node: Node,
                                 parent: Int?,
                                 setting: SpringBoneJointSetting,
                                 center: SpringBoneCenter?,
                                 to links: inout [Link]) {
        let tail: SIMD3<Float>?
        if let firstChild = node.runtimeChildren.first {
            tail = firstChild.worldPosition
        } else if let parentNode = node.runtimeParent {
            tail = springBoneLeafTail(head: node.worldPosition, parent: parentNode.worldPosition)
        } else {
            tail = nil
        }

        links.append(Link(node: node,
                          parent: parent,
                          joint: tail.flatMap { Self.joint(node: node, tail: $0, center: center) },
                          setting: setting))
        let index = links.count - 1
        for child in node.runtimeChildren {
            appendVRM0Links(below: child, parent: index, setting: setting, center: center, to: &links)
        }
    }

    private static func joint(node: Node, tail: SIMD3<Float>, center: SpringBoneCenter?) -> SpringBoneJoint? {
        let worldMatrix = node.worldMatrix
        return SpringBoneJoint(head: worldMatrix.translation,
                               localTail: worldMatrix.inverse.multiplyPoint(tail),
                               worldTail: tail,
                               initialLocalRotation: node.localRotation,
                               center: center)
    }
}
