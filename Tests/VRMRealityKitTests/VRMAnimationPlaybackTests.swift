#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Plays the hand-written `.vrma` fixture onto the bundled VRM models, driving
/// the tick directly instead of through a rendering scene.
///
/// The fixture's skeleton rests with its hips 1 m up, so every retargeted value
/// is predictable: local rotations carry over 1:1, turned 180° around Y for a VRM
/// 0.x model, and hips translations scale by the target's rest hips height.
@Suite
@MainActor
struct VRMAnimationPlaybackTests {
    private func fixture() throws -> VRMAnimation {
        try VRMAnimation(data: VRMASampleFixture.standard())
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func worldRotation(of entity: Entity, in root: Entity) -> simd_quatf {
        Transform(matrix: entity.transformMatrix(relativeTo: root)).rotation
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func worldPosition(of entity: Entity, in root: Entity) -> SIMD3<Float> {
        entity.position(relativeTo: root)
    }

    /// The angles the model's gaze is aimed at, as (yaw, pitch) in degrees. Zero for a
    /// model aimed at nothing, which is also where a gaze of nothing lands.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func gaze(of entity: VRMEntity) -> SIMD2<Float> {
        guard case .angles(let yaw, let pitch) = entity.lookAtTarget else { return .zero }
        return SIMD2(yaw, pitch)
    }

    @Test
    func testHipsRotationRetargetsOntoAVRM1Model() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))
        let rest = worldRotation(of: hips, in: entity)

        let controller = try entity.playAnimation(fixture())
        #expect(controller.animation.duration.isApproximatelyEqual(to: 1.0))
        entity.updateAnimations(deltaTime: 1.0)
        #expect(controller.time.isApproximatelyEqual(to: 1.0))

        // At t = 1 the fixture turns the hips 90° around +X in model space.
        let delta = worldRotation(of: hips, in: entity) * rest.inverse
        let expected = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        #expect(abs(simd_dot(delta, expected)) > 0.999)
    }

    @Test
    func testHipsTranslationScalesToTheTargetHipsHeight() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))
        // The fixture's hips rest 1 m up, so the retarget scale is the target's
        // own rest hips height.
        let scale = worldPosition(of: hips, in: entity).y
        #expect(scale > 0)

        try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        // The fixture moves its hips to [0, 1, 0.5]; scaled onto the target.
        let expected = SIMD3<Float>(0, scale, 0.5 * scale)
        #expect(worldPosition(of: hips, in: entity).isApproximatelyEqual(to: expected, tolerance: 0.002))
    }

    /// The hips of a `.vrma` may sit under nodes that do not rest untransformed, so
    /// their translation has to travel through the parent's whole rest transform
    /// rather than its rotation alone.
    @Test
    func testHipsTranslationTravelsThroughTheParentRestTransform() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))
        let restHeight = worldPosition(of: hips, in: entity).y

        // Under a parent lifted 0.4 m and scaled 1.5×, the fixture's hips rest
        // 1.9 m up and hold [0, 1.9, 0.75] in model space.
        let animation = try VRMAnimation(data: VRMASampleFixture.hipsUnderTransformedParent(
            parentTranslation: [0, 0.4, 0], parentScale: 1.5))
        try entity.playAnimation(animation)
        entity.updateAnimations(deltaTime: 0.5)

        // Retargeted, they stand at the target's own rest height, the rest of
        // the motion scaled with them.
        let expected = SIMD3<Float>(0, restHeight, 0.75 / 1.9 * restHeight)
        #expect(worldPosition(of: hips, in: entity).isApproximatelyEqual(to: expected, tolerance: 0.002))
    }

    /// A VRM 0.x model faces the other way than a `.vrma` is authored in, so the
    /// whole animation turns 180° around Y.
    @Test
    func testRetargetingOntoAVRM0ModelTurnsTheAnimationAround() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))
        let rest = worldRotation(of: hips, in: entity)
        let scale = worldPosition(of: hips, in: entity).y

        try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        let delta = worldRotation(of: hips, in: entity) * rest.inverse
        let expected = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        #expect(abs(simd_dot(delta, expected)) > 0.999)
        let expectedPosition = SIMD3<Float>(0, scale, -0.5 * scale)
        #expect(worldPosition(of: hips, in: entity).isApproximatelyEqual(to: expectedPosition, tolerance: 0.002))
    }

    @Test
    func testExpressionChannelsDriveVRM1Expressions() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        let controller = try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        // happy holds 0.7, which Seed-san's own binary happy clip snaps to 1;
        // aa ramps to 1.5, which clamps to the spec's 0...1.
        #expect(abs(entity.expression(for: .preset(.happy)) - 1.0) < 0.001)
        #expect(abs(entity.expression(for: .preset(.aa)) - 1.0) < 0.001)

        // Halfway up the ramp the non-binary aa carries the partial weight.
        controller.seek(to: 0.5)
        #expect(abs(entity.expression(for: .preset(.aa)) - 0.75) < 0.001)
    }

    @Test
    func testExpressionChannelsDriveVRM0BlendShapes() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()

        try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        // The 0.x model's Joy group is loaded as the happy expression.
        #expect(abs(entity.expression(for: .preset(.happy)) - 0.7) < 0.01)
    }

    /// Nothing stops two expressions of a `.vrma` from naming one node, and the
    /// weight on it belongs to both of them.
    @Test
    func testOneNodeDrivesEveryExpressionNamingIt() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        try entity.playAnimation(try VRMAnimation(data: VRMASampleFixture.contestedExpressions()))
        entity.updateAnimations(deltaTime: 0.5)

        #expect(abs(entity.expression(for: .preset(.aa)) - 0.6) < 0.001)
        #expect(abs(entity.expression(for: .preset(.ih)) - 0.6) < 0.001)
    }

    /// A file stating no gaze of its own says where the model looks through the look
    /// expressions, which retarget like any other.
    @Test
    func testLookExpressionsRetargetWhereAFileStatesNoGaze() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        try entity.playAnimation(try VRMAnimation(data: VRMASampleFixture.contestedExpressions()))
        entity.updateAnimations(deltaTime: 0.5)

        #expect(abs(entity.expression(for: .preset(.lookRight)) - 1) < 0.001)
        #expect(entity.lookAtTarget == nil)
    }

    /// A stated gaze owns the look-at, so the look expressions a file carries as well
    /// are left to it rather than doubling it.
    @Test
    func testAStatedGazeOutranksTheLookExpressionsBesideIt() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        // The gaze goes left; the expression track it comes with says right.
        let animation = try VRMAnimation(data: VRMASampleFixture.gazeAndLookExpression(yawDegrees: 45))
        try entity.playAnimation(animation)
        entity.updateAnimations(deltaTime: 0.5)

        // Seed-san maps 90° of gaze onto a full weight.
        #expect(abs(entity.expression(for: .preset(.lookLeft)) - 0.5) < 0.001)
        #expect(entity.expression(for: .preset(.lookRight)) == 0)
    }

    /// A `.vrma` states its gaze as the rotation of its look-at node, and a model whose
    /// look-at weighs expressions takes it as those weights.
    @Test
    func testTheGazeTrackDrivesAVRM1ExpressionLookAt() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        // The fixture ends 30° to the model's own left, and Seed-san maps 90° onto 1.
        #expect(gaze(of: entity).isApproximatelyEqual(to: SIMD2(30, 0), tolerance: 0.01))
        #expect(abs(entity.expression(for: .preset(.lookLeft)) - 1.0 / 3) < 0.001)
        #expect(entity.expression(for: .preset(.lookRight)) == 0)
    }

    /// The same gaze on a VRM 0.x model turns the eye bones its own curves state, the
    /// angles meaning the model's own left whichever way its version faces. The eye bone
    /// channels a `.vrma` humanoid may not carry stay unretargeted, so what the eyes do
    /// is the gaze and nothing else. Alicia is the model with eye bones.
    @Test
    func testEyeBonesTakeTheGazeRatherThanChannelsOfTheirOwn() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let eyes = [HumanoidBone.leftEye, .rightEye].compactMap { entity.humanoid.node(for: $0) }
        #expect(eyes.count == 2)
        let rests = eyes.map(\.transform.rotation)

        // The fixture aims its gaze 30° left and turns both eye bones 30° around +X.
        try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        #expect(gaze(of: entity).isApproximatelyEqual(to: SIMD2(30, 0), tolerance: 0.01))
        // Alicia maps 30° of gaze onto 10° of eye, and turns both toward its own left,
        // which is a turn about the model's up axis rather than the channels' +X.
        let left = SIMD3<Float>(-1, 0, 0)
        for (eye, rest) in zip(eyes, rests) {
            let turn = rest.conjugate * eye.transform.rotation
            #expect(abs(turn.angle * 180 / .pi - 10) < 0.05)
            #expect(abs(simd_dot(turn.axis, SIMD3<Float>(0, 1, 0))) > 0.999)
            #expect(simd_dot(simd_act(turn, SIMD3<Float>(0, 0, -1)), left) > 0)
        }
    }

    /// A file stating no gaze leaves the model's own target alone, so playing one does
    /// not undo where the caller pointed it.
    @Test
    func testAnAnimationWithoutAGazeLeavesTheTargetAlone() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        entity.lookAtTarget = .angles(yaw: 90, pitch: 0)

        try entity.playAnimation(try VRMAnimation(data: VRMASampleFixture.holdingPose(expressionWeight: 0.25)))
        entity.updateAnimations(deltaTime: 0.5)

        #expect(entity.lookAtTarget == .angles(yaw: 90, pitch: 0))
        #expect(entity.expression(for: .preset(.lookLeft)) == 1)
    }

    /// VRM 0.x spells the thumb chain proximal / intermediate / distal where VRM
    /// 1.0 spells the same three joints metacarpal / proximal / distal, so a
    /// `.vrma` poses both alike.
    @Test
    func testTheThumbChainMeansTheSameJointsInBothVersions() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for data in [TestSupport.seedSanData, TestSupport.aliciaSolidData] {
            let entity = try await VRMEntityLoader(withData: data).loadEntity()
            let thumb = try #require(entity.humanoid.node(for: .leftThumbMetacarpal))
            let next = try #require(entity.humanoid.node(for: .leftThumbProximal))
            #expect(thumb !== next)

            let rest = thumb.transform.rotation
            try entity.playAnimation(fixture())
            #expect(abs(simd_dot(thumb.transform.rotation, rest)) < 0.999)
        }
    }

    /// The three-vrm sample `.vrma`, whose skeleton rests with non-identity local
    /// rotations: its right-upper-arm channel rotates 90° around the bone's local
    /// +X, which the rest chain carries to the model's +Z, so the arm lifts
    /// sideways.
    @Test
    func testTheThreeVRMSamplePlaysOnAVRM1Model() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let arm = try #require(entity.humanoid.node(for: .rightUpperArm))
        let rest = worldRotation(of: arm, in: entity)

        let controller = try entity.playAnimation(try VRMAnimation(withURL: VRMASampleAsset.test.url))
        #expect(controller.animation.duration.isApproximatelyEqual(to: 3.0))

        entity.updateAnimations(deltaTime: 0.5)
        let swung = worldRotation(of: arm, in: entity) * rest.inverse
        #expect(abs(simd_dot(swung, simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))) > 0.999)
        #expect(abs(entity.expression(for: .preset(.happy))) < 0.001)

        controller.seek(to: 1.5)
        #expect(abs(entity.expression(for: .preset(.happy)) - 1.0) < 0.001)
        // By then the arm is back at rest.
        let restored = worldRotation(of: arm, in: entity) * rest.inverse
        #expect(abs(restored.real) > 0.999)

        // At 2.5 s the sample aims its gaze a quarter turn to the model's own left, and
        // Seed-san's look-at weighs that onto a full lookLeft.
        controller.seek(to: 2.5)
        #expect(gaze(of: entity).isApproximatelyEqual(to: SIMD2(90, 0), tolerance: 0.01))
        #expect(abs(entity.expression(for: .preset(.lookLeft)) - 1.0) < 0.001)
    }

    /// The same sample on a VRM 0.x model: the arm swing turns around with the
    /// model, and the expression lands on the migrated `joy` blend shape.
    @Test
    func testTheThreeVRMSamplePlaysOnAVRM0Model() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let arm = try #require(entity.humanoid.node(for: .rightUpperArm))
        let rest = worldRotation(of: arm, in: entity)

        let controller = try entity.playAnimation(try VRMAnimation(withURL: VRMASampleAsset.test.url))
        entity.updateAnimations(deltaTime: 0.5)
        let swung = worldRotation(of: arm, in: entity) * rest.inverse
        #expect(abs(simd_dot(swung, simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 0, 1)))) > 0.999)

        controller.seek(to: 1.5)
        #expect(abs(entity.expression(for: .preset(.happy)) - 1.0) < 0.01)
    }

    /// The bundled CC0 walk cycle, authored on neither model's skeleton, so it
    /// exercises the retargeting broadly rather than one channel at a time.
    @Test(arguments: [VRMSampleAsset.seedSan, .aliciaSolid])
    func testTheWalkCycleDrivesTheWholeBodyOfEitherModel(model: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: model.data).loadEntity()
        // Every humanoid bone the model has, so the count below is of bones
        // that actually moved rather than of bones the animation declares.
        let bones = Array(entity.humanoid.bones.values)
        let restRotations = bones.map(\.transform.rotation)

        let controller = try entity.playAnimation(try VRMAnimation(withURL: VRMASampleAsset.walk.url),
                                                  loops: true)
        #expect(controller.animation.duration.isApproximatelyEqual(to: 0.767, tolerance: 0.01))

        // A quarter into the cycle the pose is far from the rest one.
        controller.seek(to: 0.2)
        let moved = zip(bones, restRotations).filter { bone, rest in
            abs(simd_dot(bone.transform.rotation, rest)) < 0.999
        }
        #expect(moved.count >= 30, "only \(moved.count) of \(bones.count) bones moved")
    }

    /// The walk cycle was authored with the hips 0.908 m up and dips them to 82-88%
    /// of that, which retargeting has to reproduce as a band of the target's own
    /// rest height rather than as absolute metres.
    @Test
    func testTheWalkCycleScalesItsHipsToTheTargetModel() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))
        let restHeight = worldPosition(of: hips, in: entity).y

        let controller = try entity.playAnimation(try VRMAnimation(withURL: VRMASampleAsset.walk.url),
                                                  loops: true)
        var ratios: [Float] = []
        for step in 0...20 {
            controller.seek(to: controller.animation.duration * Double(step) / 20)
            ratios.append(worldPosition(of: hips, in: entity).y / restHeight)
        }

        let lowest = try #require(ratios.min())
        let highest = try #require(ratios.max())
        #expect(lowest > 0.80 && lowest < 0.86, "lowest hips ratio \(lowest)")
        #expect(highest > 0.85 && highest < 0.91, "highest hips ratio \(highest)")
    }

    /// The controller owns its runtime, so both outlive the playback.
    @Test
    func testSeekingAFinishedVRMAnimationStillPosesTheModel() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))
        let rest = worldRotation(of: hips, in: entity)

        let controller = try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 5)
        #expect(controller.isComplete)

        // Halfway between the keyframes the hips rotation slerps: 45° at t = 0.5.
        controller.seek(to: 0.5)
        let delta = worldRotation(of: hips, in: entity) * rest.inverse
        let expected = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(1, 0, 0))
        #expect(abs(simd_dot(delta, expected)) > 0.999)
    }

    /// A controller outlives its playback whenever the caller keeps it, so it
    /// must hold neither the entity nor the runtime posing the entity graph.
    @Test
    func testAKeptControllerDoesNotRetainTheAnimatedModel() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        weak var loaded: VRMEntity?
        var controller: GLTFAnimationPlaybackController?
        do {
            let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
            loaded = entity
            controller = try entity.playAnimation(fixture())
        }

        #expect(controller != nil)
        #expect(loaded == nil)
    }

    /// Two animations driving the same expression: the one started last owns it
    /// on every frame, not only on the frame it takes over.
    @Test
    func testTheLastStartedAnimationKeepsOwningASharedExpression() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        // The standard fixture ramps `aa` 0 → 1 over its second...
        try entity.playAnimation(fixture(), loops: true)
        // ...while this one holds it at 0.25 from behind.
        let holding = try VRMAnimation(data: VRMASampleFixture.holdingPose(expressionWeight: 0.25))
        let held = try entity.playAnimation(holding, loops: true)

        for _ in 0..<4 {
            entity.updateAnimations(deltaTime: 0.2)
            #expect(abs(entity.expression(for: .preset(.aa)) - 0.25) < 0.001)
        }

        // Once it stops, the ramp underneath drives the expression again: it
        // stands at 0.8 s of its second, where `aa` has passed 0.25 long ago.
        held.stop()
        entity.updateAnimations(deltaTime: 0)
        #expect(entity.expression(for: .preset(.aa)) > 0.25)
    }

    /// Pausing holds the pose against the animations the paused one outranks,
    /// rather than handing them its targets for as long as it is paused.
    @Test
    func testAPausedAnimationKeepsHoldingItsTargets() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hips = try #require(entity.humanoid.node(for: .hips))
        let rest = worldRotation(of: hips, in: entity)

        try entity.playAnimation(fixture(), loops: true)
        // 90° around +Z on the hips, and `aa` at 0.25, both started last.
        let quarter = sin(Float.pi / 4)
        let holding = try VRMAnimation(data: VRMASampleFixture.holdingPose(hipsRotation: [0, 0, quarter, quarter],
                                                                          expressionWeight: 0.25))
        let held = try entity.playAnimation(holding, loops: true)
        held.isPaused = true

        for _ in 0..<4 {
            entity.updateAnimations(deltaTime: 0.2)
            #expect(held.time.isApproximatelyEqual(to: 0, tolerance: 0.001))
            let delta = worldRotation(of: hips, in: entity) * rest.inverse
            #expect(abs(simd_dot(delta, simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))) > 0.999)
            #expect(abs(entity.expression(for: .preset(.aa)) - 0.25) < 0.001)
        }
    }

    /// `upperChest` is optional and neither bundled model has one, so its rotation
    /// has to reach the model through the bones that inherited its children.
    @Test(arguments: [VRMSampleAsset.seedSan, .aliciaSolid])
    func testAnOptionalBoneTheModelLacksRotatesItsChildrenInstead(model: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: model.data).loadEntity()
        #expect(entity.humanoid.node(for: .upperChest) == nil)
        let bones = try [HumanoidBone.neck, .leftShoulder, .rightShoulder].map {
            try #require(entity.humanoid.node(for: $0))
        }
        let rests = bones.map { worldRotation(of: $0, in: entity) }

        let animation = try VRMAnimation(data: VRMASampleFixture.rotatingUpperChest())
        try entity.playAnimation(animation)
        entity.updateAnimations(deltaTime: 0.5)

        // A VRM 0.x model faces the other way, so its whole animation turns with it.
        let isVRM0 = if case .v0 = entity.vrm { true } else { false }
        let expected = simd_quatf(angle: isVRM0 ? -.pi / 2 : .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        for (bone, rest) in zip(bones, rests) {
            let delta = worldRotation(of: bone, in: entity) * rest.inverse
            #expect(abs(simd_dot(delta, expected)) > 0.999, "\(bone.name) did not take the upperChest rotation")
        }
    }

    /// A `.vrma` is retargeted without ever being loaded as a scene, so a broken
    /// hierarchy has to be rejected where that hierarchy is built.
    @Test
    func testAnAnimationWithoutANodeHierarchyIsRejected() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let animation = try VRMAnimation(data: VRMASampleFixture.hipsWithTwoParents())
        #expect(throws: VRMError.self) { try entity.playAnimation(animation) }
    }
}
#endif
