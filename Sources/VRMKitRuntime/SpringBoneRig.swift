import Foundation
import simd
import VRMKit

/// The colliders of one group, each a shape in the space of the node it hangs
/// off. VRM 0.x hangs a whole group off a single node; VRM 1.0 gives every
/// collider its own.
package struct SpringBoneRigColliderGroup<Node: VRMRuntimeNode> {
    private let colliders: [(node: Node, shape: SpringBoneColliderShape)]

    package init(colliders: [(node: Node, shape: SpringBoneColliderShape)]) {
        self.colliders = colliders
    }

    /// Where the colliders are now. Solved as a spring asks for them, since a
    /// spring may swing a node another spring's colliders hang off.
    func appendWorldColliders(to result: inout [SpringBoneCollider]) {
        for collider in colliders {
            result.append(collider.shape.world(in: collider.node.worldMatrix))
        }
    }
}

/// Every spring of one model, and the per-frame solve that swings them.
///
/// Both renderers drive this. All that is renderer-specific is reading a node's
/// transform and writing its rotation, which ``VRMRuntimeNode`` names.
package final class SpringBoneRig<Node: VRMRuntimeNode> where Node.RuntimeNode == Node {
    /// One node of a spring, ordered so that a parent always comes before its
    /// children and a single pass composes the whole spring's world transforms.
    private struct Link {
        let node: Node
        /// The link this one hangs off. Nil for one whose parent is outside the
        /// spring, whose world transform is read from the renderer instead.
        let parent: Int?
        /// Nil for a node a spring only passes through on its way to the next
        /// joint, which VRM 1.0 allows between two joints of a chain.
        var joint: SpringBoneJoint?
        let setting: SpringBoneJointSetting
    }

    private struct Spring {
        let center: Node?
        let colliderGroups: [SpringBoneRigColliderGroup<Node>]
        var links: [Link]
    }

    private var springs: [Spring] = []
    /// Held across frames so a solve allocates nothing.
    private var colliders: [SpringBoneCollider] = []
    private var worlds: [SpringBoneWorldTransform] = []

    package init() {}

    package var isEmpty: Bool { springs.isEmpty }

    /// Advances every spring by `deltaTime`.
    package func update(deltaTime: TimeInterval) {
        let deltaTime = Float(deltaTime)
        for index in springs.indices {
            update(&springs[index], deltaTime: deltaTime)
        }
    }

    private func update(_ spring: inout Spring, deltaTime: Float) {
        colliders.removeAll(keepingCapacity: true)
        for group in spring.colliderGroups {
            group.appendWorldColliders(to: &colliders)
        }
        let center = spring.center.map { SpringBoneCenter(localToWorld: $0.worldMatrix) }

        worlds.removeAll(keepingCapacity: true)
        worlds.reserveCapacity(spring.links.count)

        for index in spring.links.indices {
            let link = spring.links[index]
            // The only world transforms the rig reads rather than composes: every
            // link below one follows from local transforms alone.
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
                                            colliders: colliders)
                spring.links[index].joint = joint
                link.node.setLocalRotation(parentWorld.rotation.inverse * rotation)
                // Composed again from the rotation the joint was swung to, which
                // is what its children hang off.
                world = link.node.worldTransform(under: parentWorld)
            }
            worlds.append(world)
        }
    }
}

// MARK: - Building

package extension SpringBoneRig {
    /// Every spring the model states, whichever version states them. `node`
    /// resolves a glTF node index to the renderer's node, the only part of
    /// building a rig that differs between the two renderers.
    static func make(vrm: VRM, node: (Int) throws -> Node) throws -> SpringBoneRig<Node> {
        let rig = SpringBoneRig<Node>()
        switch vrm {
        case .v0(let vrm0): try rig.addVRM0Springs(vrm0.secondaryAnimation, node: node)
        case .v1(let vrm1): try rig.addVRM1Springs(vrm1.springBone, node: node)
        }
        return rig
    }

    private func addVRM0Springs(_ secondaryAnimation: VRM0.SecondaryAnimation,
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

    private func addVRM1Springs(_ springBone: VRM1.SpringBone?, node: (Int) throws -> Node) throws {
        guard let springBone else { return }
        let sourceColliders = springBone.colliders ?? []
        let allColliderGroups = try (springBone.colliderGroups ?? []).map { group in
            SpringBoneRigColliderGroup<Node>(colliders: try group.colliders.map { index in
                let collider = try sourceColliders[safe: index]
                    ??? ._dataInconsistent("a collider group names collider \(index), "
                                           + "and the model holds \(sourceColliders.count)")
                return (node: try node(collider.node), shape: try SpringBoneColliderShape(vrm1Collider: collider))
            })
        }
        for spring in springBone.springs ?? [] {
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

    /// The collider groups a spring names. One naming a group the model does not
    /// hold is refused rather than swung without it, as a spring naming a node
    /// the model does not hold already is.
    private static func colliderGroups(_ groups: [SpringBoneRigColliderGroup<Node>],
                                       at indices: [Int]) throws -> [SpringBoneRigColliderGroup<Node>] {
        try indices.map { index in
            try groups[safe: index]
                ??? ._dataInconsistent("a spring names collider group \(index), "
                                       + "and the model holds \(groups.count)")
        }
    }

    /// A VRM 0.x bone group: every bone below each root swings, on the one setting
    /// the group states. Each root is its own spring.
    func addVRM0Spring(center: Node?,
                       rootBones: [Node],
                       setting: SpringBoneJointSetting,
                       colliderGroups: [SpringBoneRigColliderGroup<Node>]) {
        let centerTransform = center.map { SpringBoneCenter(localToWorld: $0.worldMatrix) }
        for root in rootBones {
            var links: [Link] = []
            appendVRM0Links(below: root, parent: nil, setting: setting, center: centerTransform, to: &links)
            append(Spring(center: center, colliderGroups: colliderGroups, links: links))
        }
    }

    /// A VRM 1.0 spring: each consecutive pair of the chain is one joint that
    /// swings, so `a-b-c-d` is `a-b`, `b-c` and `c-d`, and the last is only a tail.
    ///
    /// `VRMC_springBone` has each joint be a descendant of the one before it, so a
    /// chain that is not one descent of the hierarchy is refused.
    func addVRM1Spring(center: Node?,
                       chain: [(node: Node, setting: SpringBoneJointSetting)],
                       colliderGroups: [SpringBoneRigColliderGroup<Node>]) throws {
        guard let first = chain.first?.node else { return }
        let centerTransform = center.map { SpringBoneCenter(localToWorld: $0.worldMatrix) }
        var links: [Link] = []
        var indexOfNode: [ObjectIdentifier: Int] = [:]

        /// The nodes from the spring's first joint down to `node`, both ends
        /// included, or nil for a node that is not below it. Nodes the spec allows
        /// between two joints are composed through even though they do not swing.
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
        append(Spring(center: center, colliderGroups: colliderGroups, links: links))
    }

    /// A spring with nothing to swing is left out rather than solved every
    /// frame for no effect.
    private func append(_ spring: Spring) {
        guard spring.links.contains(where: { $0.joint != nil }) else { return }
        springs.append(spring)
    }

    /// VRM 0.x swings every bone below the root: one with children towards the
    /// first of them, and a leaf towards the tail VRM 0.x gives it.
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
