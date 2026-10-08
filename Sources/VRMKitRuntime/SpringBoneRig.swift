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
    static let step: TimeInterval = 1.0 / 60.0
    /// Time past these steps is dropped, so a long hitch stalls the swing rather than
    /// replaying it.
    static let maximumStepsPerUpdate = 4
    /// The largest change in a component of a joint's local rotation that is not
    /// written back. A spring at rest keeps returning its rest rotation, give or take
    /// the rounding of the integration, and writing a rotation costs a renderer a
    /// component update however small the change: about a thousandth of a degree.
    static let restTolerance: Float = 1e-5
    /// How close to the end of its frame a step takes the renderer's state as it is rather
    /// than interpolating it: a thousandth of the frame's motion.
    static let endOfFrameTolerance: Float = 1e-3
}

/// How a ``SpringBoneRig`` swings.
public struct SpringBoneConfiguration: Sendable {
    /// A world-space force added to every joint, scaled like gravity: wind.
    public var externalForce: SIMD3<Float>
    /// Holds every joint at the rotation it last swung to, so what hangs off the model
    /// keeps the shape it had, spread by wind or a turn, while the model moves. Swinging
    /// again carries on from that shape, with none of the motion from before the pause.
    /// Unlike UniVRM's `StopSpringBoneWriteback`, which keeps simulating and only stops
    /// writing, the simulation itself stops.
    public var isPaused: Bool

    public init(externalForce: SIMD3<Float> = .zero, isPaused: Bool = false) {
        self.externalForce = externalForce
        self.isPaused = isPaused
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
        /// Where the parent's world transform comes from when it is outside the spring.
        var mount = Mount.renderer
    }

    /// Where a link whose parent is outside its spring reads the parent's world transform.
    private enum Mount {
        /// From the renderer as it is, for a parent with nothing above it to spread.
        case renderer
        /// The parent is the anchor at this index.
        case anchor(Int)
        /// From the renderer, carried by the motion of the anchor at this index: a parent
        /// another spring swings, which hangs below that anchor.
        case carried(Int)
    }

    /// A node a spring hangs in or off that no spring swings, reached from a node the rig
    /// holds anyway rather than held itself: the rig must not hold a model holding it.
    private struct Anchor {
        let base: Node
        let levelsUp: Int

        var node: Node? {
            var node: Node? = base
            for _ in 0..<levelsUp {
                node = node?.runtimeParent
            }
            return node
        }
    }

    private struct Spring {
        let center: Node?
        /// The anchor of `center`.
        var centerAnchor: Int?
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
    /// Whether the tails have been put where the model is drawn. The rig is built where
    /// the model was loaded, and a model is usually moved, turned or scaled into place
    /// before its first frame, so the tails read at build time would swing towards where
    /// it used to be: hair or a skirt flung through its colliders on the first frame.
    private var isSettled = false
    /// Whether the last update was paused. The tails still carry the motion from before the
    /// pause, measured where the model was then, so the next swing starts them afresh.
    private var wasPaused = false
    /// Time handed to ``update(deltaTime:)`` and not yet simulated.
    private var accumulator: TimeInterval = 0
    /// The time not yet simulated when the renderer's state was last read, which is how far
    /// the steps were behind that state.
    private var accumulatorAtSample: TimeInterval = 0
    /// Whether ``anchors`` and every ``Link/mount`` match the springs. They are found once
    /// the springs are all there: a spring added later may swing what an earlier one hangs off.
    private var areAnchorsResolved = false
    /// The steps of one update spread what the anchors and colliders moved since the steps
    /// last caught up across themselves rather than moving it all in the first: a spring with
    /// little drag rings at the frame rate from that jolt whenever a frame takes several
    /// steps, or none.
    private var anchors: [Anchor] = []
    private var anchorSamples: [SpringBoneAnchorSample] = []
    /// Whether the step being solved is at the end of its frame, where the anchors and
    /// colliders are as last read. The step arrays hold them for any other step.
    private var isStepAtEnd = true
    private var stepAnchorWorlds: [SpringBoneWorldTransform] = []
    private var stepAnchorMotions: [SpringBoneStepMotion] = []
    private var stepAnchorCenters: [SpringBoneCenter?] = []

    // Held across frames so a solve allocates nothing.
    private var worldColliders: [SpringBoneCollider] = []
    private var previousWorldColliders: [SpringBoneCollider] = []
    private var stepColliders: [SpringBoneCollider] = []
    private var springColliders: [SpringBoneCollider] = []
    private var worlds: [SpringBoneWorldTransform] = []

    /// The nodes the last ``update(deltaTime:)`` wrote a rotation to, so a renderer
    /// can re-skin only what a step actually moved. A joint that settled and keeps
    /// its rotation is left out.
    package private(set) var posedNodes: [Node] = []

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
    /// Returns whether a joint was posed (``posedNodes``), so a renderer re-skins only
    /// the frames a step moved something in.
    @discardableResult
    package func update(deltaTime: TimeInterval) -> Bool {
        posedNodes.removeAll(keepingCapacity: true)
        guard !springs.isEmpty else { return false }
        resolveAnchorsIfNeeded()
        if configuration.isPaused {
            // Settling for a reset would drop the held shape, and a held joint carries no
            // motion for the reset to forget.
            pendingReset = false
            wasPaused = true
            return false
        }
        if wasPaused {
            wasPaused = false
            isSettled = true
            accumulator = 0
            restartTails(atRest: false)
            return false
        }
        if pendingReset {
            pendingReset = false
            isSettled = true
            accumulator = 0
            restartTails(atRest: true)
            return !posedNodes.isEmpty
        }
        if !isSettled {
            isSettled = true
            restartTails(atRest: true)
        }
        let step = SpringBoneSimulation.step
        accumulator = min(max(0, accumulator + deltaTime),
                          step * TimeInterval(SpringBoneSimulation.maximumStepsPerUpdate))
        guard accumulator >= step else { return !posedNodes.isEmpty }

        // The renderer's state stands still within one update, so read it once however
        // many steps the frame takes, and spread what moved since the last read across them.
        sample(fresh: false)
        let span = accumulator - accumulatorAtSample
        var stepEnd = -accumulatorAtSample
        while accumulator >= step {
            accumulator -= step
            stepEnd += step
            prepareStep(progress: Float(stepEnd / span))
            for index in springs.indices {
                self.step(&springs[index], deltaTime: Float(step))
            }
        }
        accumulatorAtSample = accumulator
        return !posedNodes.isEmpty
    }

    /// Reads where the anchors and colliders are. A fresh read forgets where they were, so
    /// the next steps spread no motion from before it.
    private func sample(fresh: Bool) {
        for index in anchors.indices {
            guard let world = anchors[index].node?.worldTransform else { continue }
            anchorSamples[index].record(world, fresh: fresh)
        }
        swap(&previousWorldColliders, &worldColliders)
        worldColliders.removeAll(keepingCapacity: true)
        worldColliders.reserveCapacity(colliderEntries.count)
        for entry in colliderEntries {
            worldColliders.append(entry.shape.world(in: entry.node.worldMatrix))
        }
        if fresh {
            previousWorldColliders = worldColliders
        }
    }

    /// Puts the anchors and colliders where they were `progress` of the way from the last
    /// read to this one.
    private func prepareStep(progress: Float) {
        isStepAtEnd = progress >= 1 - SpringBoneSimulation.endOfFrameTolerance
        guard !isStepAtEnd else { return }
        for (index, sample) in anchorSamples.enumerated() {
            let motion = SpringBoneStepMotion(from: sample.previous, to: sample.current, progress: progress)
            let world = motion.apply(to: sample.current)
            stepAnchorMotions[index] = motion
            stepAnchorWorlds[index] = world
            if sample.isCenter {
                stepAnchorCenters[index] = SpringBoneCenter(localToWorld: world.matrix)
            }
        }
        stepColliders.removeAll(keepingCapacity: true)
        for (current, previous) in zip(worldColliders, previousWorldColliders) {
            stepColliders.append(current.interpolated(from: previous, progress: progress))
        }
    }

    private func step(_ spring: inout Spring, deltaTime: Float) {
        springColliders.removeAll(keepingCapacity: true)
        for index in spring.colliderIndices {
            springColliders.append(isStepAtEnd ? worldColliders[index] : stepColliders[index])
        }
        let center = spring.centerAnchor.flatMap { isStepAtEnd ? anchorSamples[$0].currentCenter : stepAnchorCenters[$0] }

        worlds.removeAll(keepingCapacity: true)
        worlds.reserveCapacity(spring.links.count)

        for index in spring.links.indices {
            let link = spring.links[index]
            let parentWorld = parentWorld(of: link)
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
                if link.node.setLocalRotationIfMoved(parentWorld.rotation.inverse * rotation,
                                                     tolerance: SpringBoneSimulation.restTolerance) {
                    notePosed(link.node)
                    // Composed again from the rotation the joint was swung to, which its
                    // children hang off.
                    world = link.node.worldTransform(under: parentWorld)
                }
            }
            worlds.append(world)
        }
    }

    /// A node is a joint of one spring only, so a step poses it at most once. The steps
    /// of one update may list it again, which a renderer's invalidation absorbs.
    private func notePosed(_ node: Node) {
        if posedNodes.last !== node {
            posedNodes.append(node)
        }
    }

    /// Starts every tail with no motion, where its joint points: at rest, the authored
    /// rotation, or else where the joint is now. A rotation it writes is noted in ``posedNodes``.
    private func restartTails(atRest: Bool) {
        sample(fresh: true)
        accumulatorAtSample = accumulator
        for springIndex in springs.indices {
            let center = springs[springIndex].centerAnchor.flatMap { anchorSamples[$0].currentCenter }
            worlds.removeAll(keepingCapacity: true)
            worlds.reserveCapacity(springs[springIndex].links.count)
            for index in springs[springIndex].links.indices {
                let link = springs[springIndex].links[index]
                if atRest, let rest = link.joint?.restLocalRotation, link.node.setLocalRotationIfMoved(rest) {
                    notePosed(link.node)
                }
                let world = link.node.worldTransform(under: link.parent.map { worlds[$0] } ?? currentParentWorld(of: link))
                if var joint = link.joint {
                    joint.hold(head: world.translation, rotation: world.rotation, center: center)
                    springs[springIndex].links[index].joint = joint
                }
                worlds.append(world)
            }
        }
    }

    /// The world transform `link` hangs off at the step being solved: composed earlier in
    /// this pass when its parent is a link, and otherwise the only world transform the rig
    /// reads rather than composes.
    private func parentWorld(of link: Link) -> SpringBoneWorldTransform {
        if let parent = link.parent {
            return worlds[parent]
        }
        switch link.mount {
        case .renderer: return currentParentWorld(of: link)
        case .anchor(let index):
            return isStepAtEnd ? anchorSamples[index].current : stepAnchorWorlds[index]
        case .carried(let index):
            let world = currentParentWorld(of: link)
            return isStepAtEnd ? world : stepAnchorMotions[index].apply(to: world)
        }
    }

    /// The world transform the parent of `link`, outside its spring, has in the renderer now.
    private func currentParentWorld(of link: Link) -> SpringBoneWorldTransform {
        link.node.runtimeParent?.worldTransform ?? .identity
    }

    private func resolveAnchorsIfNeeded() {
        guard !areAnchorsResolved else { return }
        areAnchorsResolved = true
        anchors.removeAll()
        anchorSamples.removeAll()
        var indexOfAnchor: [ObjectIdentifier: Int] = [:]
        /// The anchor `levelsUp` above `base`.
        func anchor(_ base: Node, levelsUp: Int) -> Int? {
            let anchor = Anchor(base: base, levelsUp: levelsUp)
            guard let node = anchor.node else { return nil }
            if let index = indexOfAnchor[ObjectIdentifier(node)] { return index }
            anchors.append(anchor)
            anchorSamples.append(SpringBoneAnchorSample())
            indexOfAnchor[ObjectIdentifier(node)] = anchors.count - 1
            return anchors.count - 1
        }
        let swung = Set(springs.flatMap { $0.links.compactMap { $0.joint == nil ? nil : ObjectIdentifier($0.node) } })
        for springIndex in springs.indices {
            if let center = springs[springIndex].center, let index = anchor(center, levelsUp: 0) {
                anchorSamples[index].isCenter = true
                springs[springIndex].centerAnchor = index
            }
            for linkIndex in springs[springIndex].links.indices where springs[springIndex].links[linkIndex].parent == nil {
                let node = springs[springIndex].links[linkIndex].node
                // Everything below the highest node a spring swings moves with that swing,
                // which the steps solve themselves rather than spread.
                var levelsAboveHighestSwung: Int?
                var levelsUp = 1
                for ancestor in sequence(first: node, next: { $0.runtimeParent }).dropFirst() {
                    if swung.contains(ObjectIdentifier(ancestor)) {
                        levelsAboveHighestSwung = levelsUp + 1
                    }
                    levelsUp += 1
                }
                springs[springIndex].links[linkIndex].mount = if let levels = levelsAboveHighestSwung {
                    anchor(node, levelsUp: levels).map(Mount.carried) ?? .renderer
                } else {
                    anchor(node, levelsUp: 1).map(Mount.anchor) ?? .renderer
                }
            }
        }
        let count = anchors.count
        stepAnchorWorlds = Array(repeating: .identity, count: count)
        stepAnchorMotions = Array(repeating: .identity, count: count)
        stepAnchorCenters = Array(repeating: nil, count: count)
    }
}

/// Where a node a spring hangs in or off was when the steps last caught up with the
/// renderer, and where it is now.
private struct SpringBoneAnchorSample {
    var previous = SpringBoneWorldTransform.identity
    var current = SpringBoneWorldTransform.identity
    var isCenter = false
    /// `current` as the center of a spring, for an anchor a spring hangs in.
    var currentCenter: SpringBoneCenter?

    mutating func record(_ world: SpringBoneWorldTransform, fresh: Bool) {
        previous = fresh ? world : current
        current = world
        if isCenter {
            currentCenter = SpringBoneCenter(localToWorld: world.matrix)
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
        let jointsOfSpring = Self.jointsNamedOnce(springs)
        try Self.validateVRM1(jointsOfSpring, centers: springs.map(\.center), node: node)
        let sourceColliders = springBone.colliders ?? []
        let allColliderGroups = try (springBone.colliderGroups ?? []).map { group in
            SpringBoneRigColliderGroup<Node>(colliders: try group.colliders.map { index in
                let collider = try sourceColliders[safe: index]
                    ??? ._dataInconsistent("a collider group names collider \(index), "
                                           + "and the model holds \(sourceColliders.count)")
                return (node: try node(collider.node), shape: try SpringBoneColliderShape(vrm1Collider: collider))
            })
        }
        for (spring, joints) in zip(springs, jointsOfSpring) {
            let jointNodes = try joints.map { try node($0.node) }
            // A chain of one joint is only a tail, so it swings nothing.
            guard jointNodes.count > 1 else { continue }
            try addVRM1Spring(center: try spring.center.map { try node($0) },
                              chain: zip(jointNodes, joints).map {
                                  (node: $0, setting: try SpringBoneJointSetting(vrm1Joint: $1))
                              },
                              colliderGroups: try Self.colliderGroups(allColliderGroups,
                                                                      at: spring.colliderGroups ?? []))
        }
    }

    /// The joints of each spring, leaving out a node a joint before it already names.
    /// `VRMC_springBone` gives a node to one spring, but a model migrated from VRM 0.x can
    /// name it in several when one bone group hangs below another. UniVRM keeps it in the
    /// first spring and drops it from the later ones, so a later spring swings past it as
    /// a node between two joints, and no node is posed twice a frame.
    private static func jointsNamedOnce(_ springs: [VRM1.SpringBone.Spring]) -> [[VRM1.SpringBone.Spring.Joint]] {
        var named: Set<Int> = []
        return springs.map { spring in
            spring.joints.filter { named.insert($0.node).inserted }
        }
    }

    /// The rules `VRMC_springBone` states across springs, which building one at a time
    /// cannot see.
    private static func validateVRM1(_ jointsOfSpring: [[VRM1.SpringBone.Spring.Joint]],
                                     centers: [Int?],
                                     node: (Int) throws -> Node) throws {
        var springOfJoint: [ObjectIdentifier: Int] = [:]
        for (index, joints) in jointsOfSpring.enumerated() {
            for joint in joints {
                springOfJoint[ObjectIdentifier(try node(joint.node))] = index
            }
        }
        for (index, (joints, centerIndex)) in zip(jointsOfSpring, centers).enumerated() {
            guard let centerIndex, let first = joints.first else { continue }
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
        areAnchorsResolved = false
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
