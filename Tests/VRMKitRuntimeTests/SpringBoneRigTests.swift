import Foundation
import Testing
import simd
import VRMKit
@testable import VRMKitRuntime

/// The rig that swings a whole model's springs. It reads a node's transform through
/// ``VRMRuntimeNode``, so a plain node stands in for the renderer's.
@Suite
struct SpringBoneRigTests {
    private static let setting = SpringBoneJointSetting(stiffnessForce: 0,
                                                        gravityPower: 1,
                                                        gravityDir: SIMD3(0, -1, 0),
                                                        dragForce: 0.4,
                                                        hitRadius: 0)

    /// A chain hanging along +z, each bone one unit past the last.
    private static func chain(length: Int) -> (root: TestRuntimeNode, nodes: [TestRuntimeNode]) {
        let root = TestRuntimeNode()
        var nodes: [TestRuntimeNode] = []
        var parent = root
        for index in 0..<length {
            let node = TestRuntimeNode(translation: SIMD3(0, 0, index == 0 ? 0 : 1))
            parent.addChild(node)
            nodes.append(node)
            parent = node
        }
        return (root, nodes)
    }

    private static func vrm1Rig(_ nodes: [TestRuntimeNode]) throws -> SpringBoneRig<TestRuntimeNode> {
        let rig = SpringBoneRig<TestRuntimeNode>()
        try rig.addVRM1Spring(center: nil,
                          chain: nodes.map { (node: $0, setting: setting) },
                          colliderGroups: [])
        return rig
    }

    @Test
    func testAChainSwingsUnderGravityWithoutStretching() throws {
        let (_, nodes) = Self.chain(length: 4)
        let rig = try Self.vrm1Rig(nodes)

        for _ in 0..<60 { rig.update(deltaTime: 1.0 / 60.0) }

        // The last node of a chain is only a tail, so three joints swung.
        for (head, tail) in zip(nodes, nodes.dropFirst()) {
            #expect(abs(simd_distance(head.worldPosition, tail.worldPosition) - 1) < 1e-3)
        }
        #expect(nodes.last!.worldPosition.y < -0.5)
    }

    /// The rig composes a spring's transforms itself, so it asks the renderer where a node
    /// is only for the one it cannot derive: the node the spring hangs off.
    @Test
    func testSolvingAChainReadsOneWorldTransformWhateverItsLength() throws {
        let (root, nodes) = Self.chain(length: 8)
        let rig = try Self.vrm1Rig(nodes)
        // The first update also settles the tails, which reads the root once more.
        rig.update(deltaTime: 1.0 / 60.0)
        root.resetWorldReads()

        rig.update(deltaTime: 1.0 / 60.0)

        #expect(root.worldReads == 2)
        #expect(nodes.allSatisfy { $0.worldReads == 0 })

        // Nor once a step, when a frame takes several.
        root.resetWorldReads()
        rig.update(deltaTime: 1.0 / 30.0)
        #expect(root.worldReads == 2)
    }

    /// The rig is built where the model was loaded, and a model is usually moved into
    /// place before its first frame, so the first update starts the tails where the
    /// model is drawn rather than swinging them back towards where it was built.
    @Test
    func testTheFirstUpdateStartsTheTailsWhereTheModelIsDrawn() throws {
        let (root, nodes) = Self.chain(length: 4)
        let rig = try Self.vrm1Rig(nodes)
        root.translation = SIMD3(10, 0, 0)
        rig.update(deltaTime: 1.0 / 60.0)

        let (placedRoot, placedNodes) = Self.chain(length: 4)
        placedRoot.translation = SIMD3(10, 0, 0)
        try Self.vrm1Rig(placedNodes).update(deltaTime: 1.0 / 60.0)

        for (moved, placed) in zip(nodes, placedNodes) {
            #expect(simd_distance(moved.worldPosition, placed.worldPosition) < 1e-4)
        }
    }

    /// A rig holds the joints it swings, and a model holding the rig must not be held
    /// by it in turn.
    @Test
    func testARigDoesNotHoldWhatHangsAboveTheFirstJoint() throws {
        weak var released: TestRuntimeNode?
        var rig: SpringBoneRig<TestRuntimeNode>?
        do {
            let (root, nodes) = Self.chain(length: 4)
            released = root
            rig = try Self.vrm1Rig(nodes)
            // The chain's own nodes stay alive through the rig; the node it hangs off is
            // the model's to release.
            _ = nodes
        }

        #expect(rig != nil)
        #expect(released == nil)
    }

    /// VRM 1.0 lets a node sit between two joints of a chain. It swings nothing, but
    /// where it is decides where the joint below it hangs.
    @Test
    func testANodeBetweenTwoJointsIsComposedThroughWithoutSwinging() throws {
        let (_, nodes) = Self.chain(length: 4)
        let skipped = nodes[1]
        let rig = try Self.vrm1Rig([nodes[0], nodes[2], nodes[3]])
        let skippedRotation = skipped.localRotation

        for _ in 0..<30 { rig.update(deltaTime: 1.0 / 60.0) }

        #expect(skipped.localRotation == skippedRotation)
        #expect(nodes[3].worldPosition.y < -0.2)
        #expect(abs(simd_distance(nodes[2].worldPosition, nodes[3].worldPosition) - 1) < 1e-3)
    }

    /// `VRMC_springBone` has each joint of a chain below the one before it. A chain stated
    /// any other way says nothing about what it swings, so it is refused.
    @Test
    func testAChainWhoseJointsAreNotOneDescentIsRefused() {
        let root = TestRuntimeNode()
        let first = root.addChild(TestRuntimeNode())
        let sibling = root.addChild(TestRuntimeNode(translation: SIMD3(0, 0, 1)))
        let belowSibling = sibling.addChild(TestRuntimeNode(translation: SIMD3(0, 0, 1)))

        #expect(throws: VRMError.self) {
            try SpringBoneRig<TestRuntimeNode>().addVRM1Spring(
                center: nil,
                chain: [first, sibling, belowSibling].map { (node: $0, setting: Self.setting) },
                colliderGroups: []
            )
        }
    }

    /// Not out of the collider outright: `VRMC_springBone` puts the tail back on the bone
    /// after every hit without re-checking that last move.
    @Test
    func testAColliderPushesATailAwayFromWhereItWouldOtherwiseHang() throws {
        let collider = try JSONDecoder().decode(
            VRM0.SecondaryAnimation.ColliderGroup.Collider.self,
            from: Data(#"{"offset": {"x": 0, "y": 0, "z": 0}, "radius": 0.4}"#.utf8)
        )

        func tailPosition(collides: Bool) throws -> SIMD3<Float> {
            let (root, nodes) = Self.chain(length: 2)
            let colliderNode = root.addChild(TestRuntimeNode(translation: SIMD3(0, -0.5, 0.5)))
            let rig = SpringBoneRig<TestRuntimeNode>()
            try rig.addVRM1Spring(center: nil,
                                  chain: nodes.map { (node: $0, setting: Self.setting) },
                                  colliderGroups: collides ? [SpringBoneRigColliderGroup(colliders: [
                                  (node: colliderNode, shape: SpringBoneColliderShape(vrm0Collider: collider))
                              ])] : [])
            for _ in 0..<120 { rig.update(deltaTime: 1.0 / 60.0) }
            return nodes[1].worldPosition
        }

        let colliderPosition = SIMD3<Float>(0, -0.5, 0.5)
        let radius: Float = 0.4
        let pushed = try tailPosition(collides: true)
        let free = try tailPosition(collides: false)

        // Without the collider the tail hangs straight past it.
        #expect(simd_distance(free, colliderPosition) > radius + 0.2)
        // With it the tail comes to rest on the collider instead.
        #expect(abs(simd_distance(pushed, colliderPosition) - radius) < 0.05)
    }

    /// The two versions disagree about the end of a chain: VRM 0.x swings a leaf around
    /// the 7cm tail it gives it, while a VRM 1.0 chain's last joint is only a tail.
    @Test
    func testOnlyVRM0SwingsTheLeafAtTheEndOfAChain() throws {
        func leafRotation(vrm0: Bool) throws -> simd_quatf {
            let (_, nodes) = Self.chain(length: 3)
            let rig = SpringBoneRig<TestRuntimeNode>()
            if vrm0 {
                rig.addVRM0Spring(center: nil,
                                  rootBones: [nodes[0]],
                                  setting: Self.setting,
                                  colliderGroups: [])
            } else {
                try rig.addVRM1Spring(center: nil,
                                      chain: nodes.map { (node: $0, setting: Self.setting) },
                                      colliderGroups: [])
            }
            for _ in 0..<60 { rig.update(deltaTime: 1.0 / 60.0) }
            return nodes[2].localRotation
        }

        // A leaf swung by a 7cm tail settles almost where it started once the chain above
        // it hangs straight down, so what separates the two is that one is solved at all.
        #expect(try leafRotation(vrm0: true) != .identity)
        #expect(try leafRotation(vrm0: false) == .identity)
    }

    /// The simulation steps at its own fixed rate, so a chain drawn at 30 fps and one at
    /// 120 fps swing to the same place after the same time.
    @Test
    func testTheSwingIsTheSameAtEveryFrameRate() throws {
        func settled(frameTime: TimeInterval, frames: Int) throws -> SIMD3<Float> {
            let (_, nodes) = Self.chain(length: 4)
            let rig = try Self.vrm1Rig(nodes)
            for _ in 0..<frames { rig.update(deltaTime: frameTime) }
            return nodes.last!.worldPosition
        }

        let baseline = try settled(frameTime: 1.0 / 60.0, frames: 60)
        #expect(simd_distance(try settled(frameTime: 1.0 / 30.0, frames: 30), baseline) < 1e-4)
        #expect(simd_distance(try settled(frameTime: 1.0 / 120.0, frames: 120), baseline) < 1e-4)
    }

    private static let lightlyDamped = SpringBoneJointSetting(stiffnessForce: 0.5,
                                                              gravityPower: 1,
                                                              gravityDir: SIMD3(0, -1, 0),
                                                              dragForce: 0.05,
                                                              hitRadius: 0)

    /// Turns and moves `root` steadily for a second, drawn at `frameRate`, as tracking
    /// poses a model, and updates `rig` every frame.
    private static func drive(_ rig: SpringBoneRig<TestRuntimeNode>, moving root: TestRuntimeNode, frameRate: Int) {
        func place(at time: Double) {
            root.translation = SIMD3(Float(time) * 0.5, 0, 0)
            root.rotation = simd_quatf(angle: Float(time) * 0.8, axis: SIMD3(0, 1, 0))
        }
        place(at: 0)
        rig.update(deltaTime: 0)
        for frame in 1...frameRate {
            place(at: Double(frame) / Double(frameRate))
            rig.update(deltaTime: 1 / Double(frameRate))
        }
    }

    /// The steps of one update spread what the spring hangs off has moved across
    /// themselves, so a model moving under a spring swings it the same at 30 fps as at 60
    /// rather than jolting it once a frame.
    @Test(arguments: [false, true])
    func testAMovingModelSwingsTheSameAtEveryFrameRate(measuredInTheRoot: Bool) throws {
        func swung(frameRate: Int) throws -> SIMD3<Float> {
            let (root, nodes) = Self.chain(length: 4)
            let rig = SpringBoneRig<TestRuntimeNode>()
            try rig.addVRM1Spring(center: measuredInTheRoot ? root : nil,
                                  chain: nodes.map { (node: $0, setting: Self.lightlyDamped) },
                                  colliderGroups: [])
            Self.drive(rig, moving: root, frameRate: frameRate)
            return nodes.last!.worldPosition
        }

        #expect(simd_distance(try swung(frameRate: 30), try swung(frameRate: 60)) < 1e-4)
    }

    /// A spring hanging off a joint of another moves with that joint as the step swings it,
    /// and with the model as the step puts it.
    @Test
    func testASpringHangingOffAnotherSwingsTheSameAtEveryFrameRate() throws {
        func swung(frameRate: Int) throws -> SIMD3<Float> {
            let (root, nodes) = Self.chain(length: 4)
            let branch = nodes[1].addChild(TestRuntimeNode(translation: SIMD3(1, 0, 0)))
            let branchTail = branch.addChild(TestRuntimeNode(translation: SIMD3(0, 0, 1)))
            let rig = SpringBoneRig<TestRuntimeNode>()
            try rig.addVRM1Spring(center: nil,
                                  chain: nodes.map { (node: $0, setting: Self.lightlyDamped) },
                                  colliderGroups: [])
            try rig.addVRM1Spring(center: nil,
                                  chain: [branch, branchTail].map { (node: $0, setting: Self.lightlyDamped) },
                                  colliderGroups: [])
            Self.drive(rig, moving: root, frameRate: frameRate)
            return branchTail.worldPosition
        }

        #expect(simd_distance(try swung(frameRate: 30), try swung(frameRate: 60)) < 1e-4)
    }

    /// A joint's own center carrying all of its motion swings the joint as the spring's
    /// center does, and one carrying none as if there were no center.
    @Test(arguments: [Float(0), 1])
    func testAPartialCenterCarryingAllOrNoneMatchesASpringCenterOrNone(share: Float) throws {
        func swung(center: Bool, partialShare: Float?) throws -> SIMD3<Float> {
            let (root, nodes) = Self.chain(length: 4)
            let rig = SpringBoneRig<TestRuntimeNode>()
            try rig.addVRM1Spring(center: center ? root : nil,
                                  chain: nodes.map { (node: $0, setting: Self.lightlyDamped) },
                                  colliderGroups: [])
            if let partialShare {
                for joint in nodes.dropLast() {
                    try rig.setCenter(root, share: partialShare, forJoint: joint)
                }
            }
            Self.drive(rig, moving: root, frameRate: 60)
            return nodes.last!.worldPosition
        }

        let expected = try swung(center: share == 1, partialShare: nil)
        // The spring's own center gives way to the joints'.
        #expect(simd_distance(try swung(center: share == 0, partialShare: share), expected) < 1e-4)
    }

    /// Part of the motion carries the tail part of the way between swinging freely and
    /// being carried along as if nothing moved.
    @Test
    func testAPartialCenterCarriesPartOfTheMotion() throws {
        /// How far from where it hangs off a root that stays still the tip ends up, measured
        /// in the moving root's space.
        func deviation(share: Float?) throws -> Float {
            func tip(moving: Bool) throws -> SIMD3<Float> {
                let (root, nodes) = Self.chain(length: 4)
                let rig = SpringBoneRig<TestRuntimeNode>()
                try rig.addVRM1Spring(center: nil,
                                      chain: nodes.map { (node: $0, setting: Self.setting) },
                                      colliderGroups: [])
                if let share {
                    for joint in nodes.dropLast() {
                        try rig.setCenter(root, share: share, forJoint: joint)
                    }
                }
                if moving {
                    Self.drive(rig, moving: root, frameRate: 60)
                } else {
                    rig.update(deltaTime: 0)
                    for _ in 0..<60 { rig.update(deltaTime: 1.0 / 60.0) }
                }
                return root.uncountedWorldMatrix.inverse.multiplyPoint(nodes.last!.worldPosition)
            }
            return simd_distance(try tip(moving: true), try tip(moving: false))
        }

        let free = try deviation(share: nil)
        let half = try deviation(share: 0.5)
        let carried = try deviation(share: 1)
        #expect(carried < 1e-3)
        #expect(carried < half)
        #expect(half < free)
    }

    /// A joint's center is held to what a spring's center is: above the joint, and swung
    /// by no spring. Only a joint that swings takes one.
    @Test
    func testAPartialCenterThatCannotBeOneIsRefused() throws {
        let (root, nodes) = Self.chain(length: 4)
        let rig = SpringBoneRig<TestRuntimeNode>()
        try rig.addVRM1Spring(center: nil,
                              chain: nodes.map { (node: $0, setting: Self.lightlyDamped) },
                              colliderGroups: [])

        #expect(throws: VRMError.self) { try rig.setCenter(nodes[2], share: 0.5, forJoint: nodes[1]) }
        #expect(throws: VRMError.self) { try rig.setCenter(nodes[0], share: 0.5, forJoint: nodes[2]) }
        #expect(throws: VRMError.self) { try rig.setCenter(root, share: 0.5, forJoint: nodes[3]) }
        #expect(throws: VRMError.self) { try rig.setCenter(root, share: 1.5, forJoint: nodes[1]) }
        try rig.setCenter(root, share: 0.5, forJoint: nodes[1])
    }

    /// A frame shorter than one step carries into the next update rather than swinging
    /// a partial step of its own.
    @Test
    func testTimeShortOfAStepIsCarriedToTheNextUpdate() throws {
        let (_, nodes) = Self.chain(length: 2)
        let rig = try Self.vrm1Rig(nodes)
        let rest = nodes[1].worldPosition

        rig.update(deltaTime: 1.0 / 240.0)
        #expect(nodes[1].worldPosition == rest)

        for _ in 0..<3 { rig.update(deltaTime: 1.0 / 240.0) }
        #expect(nodes[1].worldPosition != rest)
    }

    /// A hitch longer than the budgeted steps stalls the swing rather than replaying the
    /// missing time as one violent frame.
    @Test
    func testAHitchSimulatesNoMoreThanTheBudgetedSteps() throws {
        func settled(_ body: (SpringBoneRig<TestRuntimeNode>) -> Void) throws -> SIMD3<Float> {
            let (_, nodes) = Self.chain(length: 4)
            let rig = try Self.vrm1Rig(nodes)
            body(rig)
            return nodes.last!.worldPosition
        }

        let budgeted = try settled { rig in
            for _ in 0..<SpringBoneSimulation.maximumStepsPerUpdate {
                rig.update(deltaTime: 1.0 / 60.0)
            }
        }
        #expect(try settled { $0.update(deltaTime: 10) } == budgeted)
    }

    /// A reset starts the next update from the rest pose, so teleporting a model does not
    /// read as a swing.
    @Test
    func testAResetSettlesTheChainBackToRest() throws {
        let (_, nodes) = Self.chain(length: 4)
        let rig = try Self.vrm1Rig(nodes)
        let rest = nodes.map(\.localRotation)

        for _ in 0..<30 { rig.update(deltaTime: 1.0 / 60.0) }
        #expect(nodes.map(\.localRotation) != rest)

        rig.reset()
        rig.update(deltaTime: 1.0 / 60.0)
        #expect(nodes.map(\.localRotation) == rest)

        // The next update swings again, from rest rather than the motion carried before it.
        rig.update(deltaTime: 1.0 / 60.0)
        #expect(abs(simd_distance(nodes[0].worldPosition, nodes[1].worldPosition) - 1) < 1e-3)
    }

    @Test
    func testAnExternalForcePushesTheChainAlongItself() throws {
        let (_, nodes) = Self.chain(length: 4)
        let rig = try Self.vrm1Rig(nodes)
        rig.configuration.externalForce = SIMD3(5, 0, 0)

        for _ in 0..<60 { rig.update(deltaTime: 1.0 / 60.0) }

        #expect(nodes.last!.worldPosition.x > 0.2)
    }

    /// A paused chain keeps the shape it swung to and rides along with what it hangs off,
    /// and a reset while paused does not undo the shape.
    @Test
    func testAPausedChainHoldsTheShapeItSwungTo() throws {
        let (root, nodes) = Self.chain(length: 4)
        let rig = try Self.vrm1Rig(nodes)
        rig.configuration.externalForce = SIMD3(5, 0, 0)
        for _ in 0..<30 { rig.update(deltaTime: 1.0 / 60.0) }
        let held = nodes.map(\.localRotation)

        rig.configuration.isPaused = true
        root.translation = SIMD3(0, 3, 0)
        rig.reset()
        for _ in 0..<30 {
            #expect(rig.update(deltaTime: 1.0 / 60.0) == false)
        }

        #expect(nodes.map(\.localRotation) == held)
    }

    /// Resuming swings on from the held shape, not from the motion before the pause, which
    /// was measured where the model was then and would fling the chain across the move.
    @Test
    func testResumingSwingsOnFromTheHeldShape() throws {
        let (root, nodes) = Self.chain(length: 4)
        let rig = try Self.vrm1Rig(nodes)
        for _ in 0..<5 { rig.update(deltaTime: 1.0 / 60.0) }
        let held = nodes.map(\.worldPosition)

        rig.configuration.isPaused = true
        rig.update(deltaTime: 1.0 / 60.0)
        root.translation = SIMD3(10, 0, 0)
        rig.configuration.isPaused = false
        rig.update(deltaTime: 1.0 / 60.0)
        rig.update(deltaTime: 1.0 / 60.0)

        // Gravity alone moves each joint by little in one step; the motion from before the
        // pause would swing the chain back towards x = 0.
        let moved = nodes.last!.worldPosition - (held.last! + SIMD3(10, 0, 0))
        #expect(simd_length(moved) < 0.1)
    }

    /// A display drawing faster than the fixed step leaves frames where nothing swung, and
    /// an update says so rather than having a renderer re-skin for nothing.
    @Test
    func testAnUpdateReportsWhetherItPosedAnything() throws {
        let (_, nodes) = Self.chain(length: 4)
        let rig = try Self.vrm1Rig(nodes)

        #expect(rig.update(deltaTime: 1.0 / 120.0) == false)
        #expect(rig.update(deltaTime: 1.0 / 120.0) == true)

        // A reset poses the chain back to rest; a rig with nothing to swing never poses.
        rig.reset()
        #expect(rig.update(deltaTime: 0) == true)
        #expect(SpringBoneRig<TestRuntimeNode>().update(deltaTime: 1) == false)
    }

    // MARK: - VRMC_springBone validation

    /// `VRMC_springBone` gives each joint one spring, but a model migrated from VRM 0.x can
    /// name a node in several. It stays with the first, so no node is posed twice a frame.
    @Test
    func testANodeSeveralSpringsNameIsSwungByTheFirstOnly() throws {
        let (rig, nodes) = try Self.build(springs: [[1, 2, 3], [2, 3, 4, 5], [1, 2, 3]])
        rig.configuration.externalForce = SIMD3(0, -1, 0)
        rig.update(deltaTime: SpringBoneSimulation.step)

        // The second spring keeps only 4-5, and the third nothing.
        let posed = rig.posedNodes.map(ObjectIdentifier.init)
        #expect(posed.count == 3)
        #expect(Set(posed) == Set([nodes[1], nodes[2], nodes[4]].map(ObjectIdentifier.init)))
    }

    /// `VRMC_springBone` has a spring's centre be its first joint or a node above it.
    @Test
    func testACentreBelowTheSpringsFirstJointIsRefused() throws {
        #expect(throws: VRMError.self) {
            try Self.build(springs: [[2, 3]], centers: [4])
        }
        try Self.build(springs: [[2, 3]], centers: [2])
        try Self.build(springs: [[2, 3]], centers: [0])
    }

    /// A centre another spring swings would move under the spring hanging in it.
    @Test
    func testACentreAnotherSpringSwingsIsRefused() throws {
        #expect(throws: VRMError.self) {
            try Self.build(springs: [[1, 2], [3, 4]], centers: [nil, 2])
        }
        try Self.build(springs: [[1, 2], [3, 4]], centers: [nil, 0])
    }

    /// Builds the springs a `VRMC_springBone` states, by node index into one chain
    /// hanging off a root.
    /// - Returns: The rig, and the nodes the springs index: the root, then the chain.
    @discardableResult
    private static func build(springs: [[Int]],
                              centers: [Int?] = []) throws -> (rig: SpringBoneRig<TestRuntimeNode>, nodes: [TestRuntimeNode]) {
        let (root, nodes) = chain(length: 5)
        let all = [root] + nodes
        let stated = zip(springs, centers + Array(repeating: nil, count: springs.count)).map {
            var spring: [String: JSONValue] = ["joints": .array($0.map { ["node": .int($0)] })]
            spring["center"] = $1.map(JSONValue.int)
            return JSONValue.object(spring)
        }
        let springBone = try JSONValue.object(["specVersion": "1.0", "springs": .array(stated)])
            .decode(VRM1.SpringBone.self)

        let rig = SpringBoneRig<TestRuntimeNode>()
        try rig.addVRM1Springs(springBone) { all[$0] }
        return (rig, all)
    }

    /// A non-uniform scale above a rotation shears the matrix below it, which no
    /// translation-rotation-scale triple holds, so composing one is the only way
    /// a chain lands where the scene graph puts it.
    @Test
    func testComposingAChainMatchesTheSceneGraphUnderANonUniformScale() {
        let root = TestRuntimeNode(translation: SIMD3(0.3, -0.2, 0.1),
                                   rotation: simd_quatf(angle: .pi / 5, axis: SIMD3(0, 0, 1)),
                                   scale: SIMD3(2, 1, 1))
        let child = root.addChild(
            TestRuntimeNode(translation: SIMD3(0, 1, 0),
                            rotation: simd_quatf(angle: .pi / 3, axis: simd_normalize(SIMD3(1, 1, 0))))
        )
        let grandchild = child.addChild(
            TestRuntimeNode(translation: SIMD3(0.4, 0.7, -0.2),
                            rotation: simd_quatf(angle: -.pi / 4, axis: SIMD3(1, 0, 0)))
        )

        let composedChild = child.worldTransform(under: root.worldTransform)
        let composedGrandchild = grandchild.worldTransform(under: composedChild)

        // The node's own world transform is the plain product of the local
        // matrices above it, which is what a composed one has to land on.
        #expect(composedChild.matrix.isApproximatelyEqual(to: child.worldMatrix))
        #expect(composedGrandchild.matrix.isApproximatelyEqual(to: grandchild.worldMatrix))
    }
}

private extension simd_float4x4 {
    func isApproximatelyEqual(to other: simd_float4x4, tolerance: Float = 1e-5) -> Bool {
        (0..<4).allSatisfy { simd_distance(self[$0], other[$0]) < tolerance }
    }
}
