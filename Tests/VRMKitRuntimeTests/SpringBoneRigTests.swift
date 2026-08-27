import Foundation
import Testing
import simd
import VRMKit
@testable import VRMKitRuntime

/// The rig that swings a whole model's springs. It reads a node's transform
/// through ``VRMRuntimeNode``, so a plain node stands in for either
/// renderer's and the orchestration is testable without one.
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

    /// Gravity pulls a hanging chain down, and every bone keeps the length it
    /// was authored with.
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

    /// The rig composes a spring's transforms itself, so solving it asks the
    /// renderer where a node is only for the one it cannot derive: the node the
    /// spring hangs off, whose matrix and rotation it reads once each.
    @Test
    func testSolvingAChainReadsOneWorldTransformWhateverItsLength() throws {
        let (root, nodes) = Self.chain(length: 8)
        let rig = try Self.vrm1Rig(nodes)
        root.resetWorldReads()

        rig.update(deltaTime: 1.0 / 60.0)

        #expect(root.worldReads == 2)
        #expect(nodes.allSatisfy { $0.worldReads == 0 })
    }

    /// A rig holds the joints it swings, and a model that holds the rig must
    /// not be held by it in turn.
    @Test
    func testARigDoesNotHoldWhatHangsAboveTheFirstJoint() throws {
        weak var released: TestRuntimeNode?
        var rig: SpringBoneRig<TestRuntimeNode>?
        do {
            let (root, nodes) = Self.chain(length: 4)
            released = root
            rig = try Self.vrm1Rig(nodes)
            // The chain's own nodes stay alive through the rig; the node it
            // hangs off is the model's to release.
            _ = nodes
        }

        #expect(rig != nil)
        #expect(released == nil)
    }

    /// VRM 1.0 lets a node sit between two joints of a chain. It swings
    /// nothing, but where it is decides where the joint below it hangs.
    @Test
    func testANodeBetweenTwoJointsIsComposedThroughWithoutSwinging() throws {
        let (_, nodes) = Self.chain(length: 4)
        let skipped = nodes[1]
        let rig = try Self.vrm1Rig([nodes[0], nodes[2], nodes[3]])
        let skippedRotation = skipped.localRotation

        for _ in 0..<30 { rig.update(deltaTime: 1.0 / 60.0) }

        #expect(skipped.localRotation == skippedRotation)
        // The joints on either side of it still swing, and still reach as far
        // as they were drawn.
        #expect(nodes[3].worldPosition.y < -0.2)
        #expect(abs(simd_distance(nodes[2].worldPosition, nodes[3].worldPosition) - 1) < 1e-3)
    }

    /// `VRMC_springBone` has each joint of a chain below the one before it. A
    /// chain stated any other way says nothing about what it swings, so it is
    /// refused rather than swung as whatever the hierarchy happens to say.
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

    /// Not out of the collider outright: `VRMC_springBone` puts the tail back on
    /// the bone after every hit without re-checking that last move.
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

    /// The two versions disagree about the end of a chain: VRM 0.x swings a
    /// leaf around the 7cm tail it gives it, while a VRM 1.0 chain's last joint
    /// is only the tail the one above it swings towards.
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

        // A leaf swung by a 7cm tail settles almost where it started once the
        // chain above it hangs straight down, so what separates the two is that
        // one is solved at all and the other is never written.
        #expect(try leafRotation(vrm0: true) != .identity)
        #expect(try leafRotation(vrm0: false) == .identity)
    }
}
