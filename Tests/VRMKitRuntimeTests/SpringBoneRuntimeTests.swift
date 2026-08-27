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

        let setting = try SpringBoneJointSetting(vrm1Joint: joint)

        #expect(setting.stiffnessForce == 1.0)
        #expect(setting.gravityPower == 0.0)
        #expect(setting.gravityDir == SIMD3<Float>(0, -1, 0))
        #expect(setting.dragForce == 0.5)
        #expect(setting.hitRadius == 0.0)
    }

    /// A joint the simulation cannot swing fails the model rather than swinging
    /// on a negative stiffness, or on a drag force that grows last frame's move
    /// instead of damping it.
    @Test(arguments: [#"{"node": 3, "dragForce": 1.5}"#,
                      #"{"node": 3, "stiffness": -1}"#,
                      #"{"node": 3, "gravityPower": -1}"#])
    func testAJointOutsideTheRangesItsSpecStatesIsRefused(json: String) throws {
        let joint = try JSONDecoder().decode(VRM1.SpringBone.Spring.Joint.self, from: Data(json.utf8))

        #expect(throws: VRMError.self) { try SpringBoneJointSetting(vrm1Joint: joint) }
    }

    /// A `VRMC_springBone` collider states a sphere or a capsule. One that
    /// states neither still collides, since a joint adds its own hit radius to
    /// the collider's, so it is refused rather than kept at zero radius.
    @Test(arguments: [#"{"node": 0, "shape": {}}"#,
                      #"{"node": 0, "shape": {"sphere": {"offset": [0, 0, 0], "radius": 1},"#
                          + #""capsule": {"offset": [0, 0, 0], "radius": 1, "tail": [0, 1, 0]}}}"#])
    func testAColliderThatIsNeitherASphereNorACapsuleIsRefused(json: String) throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VRM1.SpringBone.Collider.self, from: Data(json.utf8))
        }
    }

    /// A radius the simulation cannot collide against fails the model.
    @Test
    func testAColliderWithANegativeRadiusIsRefused() throws {
        let json = #"{"node": 0, "shape": {"sphere": {"offset": [0, 0, 0], "radius": -1}}}"#
        let collider = try JSONDecoder().decode(VRM1.SpringBone.Collider.self, from: Data(json.utf8))

        #expect(throws: VRMError.self) { try SpringBoneColliderShape(vrm1Collider: collider) }
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

    /// `simd_quatf(from:to:)` asks for unit vectors, and the bone the joint
    /// points along is as long as the bone. A rotation carrying that length
    /// scales whatever it is applied to.
    @Test(arguments: [Float(0.07), 1, 12])
    func testTheRotationAJointAnswersWithIsAUnitQuaternion(boneLength: Float) throws {
        var joint = try #require(SpringBoneJoint(head: .zero,
                                                 localTail: SIMD3(0, 0, 1),
                                                 worldTail: SIMD3(0, 0, boneLength),
                                                 initialLocalRotation: Self.identity,
                                                 center: nil))

        for _ in 0..<30 {
            let rotation = joint.update(deltaTime: 1.0 / 60.0,
                                        setting: Self.setting,
                                        head: .zero,
                                        parentRotation: Self.identity,
                                        center: nil,
                                        colliders: [])
            #expect(abs(simd_length(rotation) - 1) < 1e-5)
        }
    }

    /// The stiffness and gravity terms scale with the step while the inertia
    /// carries last frame's move unscaled, so the multi-second step the first
    /// frame after a pause asks for would throw every tail past its bone.
    @Test
    func testASteppedFrameSwingsNoFurtherThanTheLongestStep() throws {
        func swing(afterStepping deltaTime: Float) throws -> SIMD3<Float> {
            var joint = try #require(SpringBoneJoint(head: .zero,
                                                     localTail: SIMD3(0, 0, 1),
                                                     worldTail: SIMD3(0, 0, 1),
                                                     initialLocalRotation: Self.identity,
                                                     center: nil))
            let rotation = joint.update(deltaTime: deltaTime,
                                        setting: Self.setting,
                                        head: .zero,
                                        parentRotation: Self.identity,
                                        center: nil,
                                        colliders: [])
            return rotation * SIMD3<Float>(0, 0, 1)
        }

        let clamped = try swing(afterStepping: SpringBoneJoint.maximumDeltaTime)
        for hitch in [Float(0.5), 2, 120] {
            #expect(simd_distance(try swing(afterStepping: hitch), clamped) < 1e-5)
        }
    }
}
