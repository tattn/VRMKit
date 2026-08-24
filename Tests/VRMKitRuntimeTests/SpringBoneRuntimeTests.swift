import Foundation
import Testing
import simd
import VRMKit
import VRMKitRuntime

/// The spring bone simulation both renderers swing their bones with.
@Suite
struct SpringBoneRuntimeTests {
    private static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    private static let setting = SpringBoneJointSetting(stiffnessForce: 1,
                                                        gravityPower: 1,
                                                        gravityDir: SIMD3(0, -1, 0),
                                                        dragForce: 0.5,
                                                        hitRadius: 0.02)

    /// A model stating none of the joint fields swings on the defaults
    /// `VRMC_springBone` declares, not on VRM 0.x's.
    @Test
    func testAVRM1JointFallsBackToTheDefaultsItsSpecDeclares() throws {
        let joint = try JSONDecoder().decode(VRM1.SpringBone.Spring.Joint.self,
                                             from: Data(#"{"node": 3}"#.utf8))

        let setting = SpringBoneJointSetting(vrm1Joint: joint)

        #expect(setting.stiffnessForce == 1.0)
        #expect(setting.gravityPower == 0.0)
        #expect(setting.gravityDir == SIMD3<Float>(0, -1, 0))
        #expect(setting.dragForce == 0.5)
        #expect(setting.hitRadius == 0.0)
    }

    /// The length a joint holds its tail at is the world distance to it, so a
    /// scaled joint swings the bone the length it is drawn at.
    @Test
    func testBoneLengthIsMeasuredInWorldSpace() throws {
        // A joint whose space is scaled by two.
        let joint = try #require(SpringBoneJoint(head: .zero,
                                                 localTail: SIMD3(0, -1, 0),
                                                 worldTail: SIMD3(0, -2, 0),
                                                 initialLocalRotation: Self.identity,
                                                 center: nil))

        #expect(joint.boneLength == 2)
        #expect(joint.boneAxis == SIMD3<Float>(0, -1, 0))
    }

    /// A pair with no length has no direction to swing in either, and
    /// normalizing one would leave NaN in every frame that follows.
    @Test
    func testAPairWithNoLengthIsNotSimulated() {
        let head = SIMD3<Float>(1, 2, 3)

        #expect(SpringBoneJoint(head: head,
                                localTail: .zero,
                                worldTail: head,
                                initialLocalRotation: Self.identity,
                                center: nil) == nil)
    }

    /// A tail sitting exactly on a collider has no direction to be pushed out
    /// along, which must not leave the joint rotating by NaN.
    @Test
    func testATailSittingOnAColliderStillRotatesFinitely() throws {
        var joint = try #require(SpringBoneJoint(head: .zero,
                                                 localTail: SIMD3(0, -1, 0),
                                                 worldTail: SIMD3(0, -1, 0),
                                                 initialLocalRotation: Self.identity,
                                                 center: nil))
        let collider = SpringBoneCollider(head: SIMD3(0, -1, 0), tail: nil, radius: 0.1)

        let rotation = joint.update(deltaTime: 1.0 / 60.0,
                                    setting: Self.setting,
                                    head: .zero,
                                    parentRotation: Self.identity,
                                    center: nil,
                                    colliders: [collider])

        #expect(simd_length(rotation.vector).isFinite)
    }

    /// Gravity swings the tail towards where it pulls, and the joint turns to
    /// follow it.
    @Test
    func testGravitySwingsTheJointTowardsWhereItPulls() throws {
        var joint = try #require(SpringBoneJoint(head: .zero,
                                                 localTail: SIMD3(0, 0, 1),
                                                 worldTail: SIMD3(0, 0, 1),
                                                 initialLocalRotation: Self.identity,
                                                 center: nil))
        let setting = SpringBoneJointSetting(stiffnessForce: 0,
                                             gravityPower: 1,
                                             gravityDir: SIMD3(0, -1, 0),
                                             dragForce: 0.5,
                                             hitRadius: 0)

        var rotation = Self.identity
        for _ in 0..<30 {
            rotation = joint.update(deltaTime: 1.0 / 60.0,
                                    setting: setting,
                                    head: .zero,
                                    parentRotation: Self.identity,
                                    center: nil,
                                    colliders: [])
        }

        // The bone still reaches as far as it did, and now hangs below where
        // it started.
        let tail = rotation * SIMD3<Float>(0, 0, 1)
        #expect(abs(simd_length(tail) - 1) < 1e-4)
        #expect(tail.y < 0)
    }
}
