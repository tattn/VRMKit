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
/// The fixture's skeleton (see ``VRMASampleFixture``) rests with its hips 1 m
/// up, so on a normalized target every retargeted value is predictable: local
/// rotations carry over 1:1 (turned 180° around Y for a VRM 0.x model), and
/// hips translations scale by the target's rest hips height.
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

    @Test
    func testHipsRotationRetargetsOntoAVRM1Model() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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
    func testHipsTranslationScalesToTheTargetHipsHeight() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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

    /// The hips of a `.vrma` may sit under nodes that do not rest untransformed,
    /// as the VRM Add-on for Blender's `Armature` node does. Their translation
    /// travels through the parent's whole rest transform, not its rotation
    /// alone, or it lands at the wrong height.
    @Test
    func testHipsTranslationTravelsThroughTheParentRestTransform() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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

    /// A VRM 0.x model faces the other way than the VRM 1.0 convention `.vrma`
    /// files are authored in, so the whole animation turns 180° around Y:
    /// a rotation around +X becomes one around −X, and the hips move to −Z.
    @Test
    func testRetargetingOntoAVRM0ModelTurnsTheAnimationAround() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
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
    func testExpressionChannelsDriveVRM1Expressions() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

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
    func testExpressionChannelsDriveVRM0BlendShapes() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()

        try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        // happy lands on the VRM 0.x preset it migrates to: joy.
        #expect(abs(entity.blendShape(for: .preset(.joy)) - 0.7) < 0.01)
    }

    /// Nothing stops two expressions of a `.vrma` from naming one node, and the
    /// weight on it belongs to both of them.
    @Test
    func testOneNodeDrivesEveryExpressionNamingIt() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        try entity.playAnimation(try VRMAnimation(data: VRMASampleFixture.contestedExpressions()))
        entity.updateAnimations(deltaTime: 0.5)

        #expect(abs(entity.expression(for: .preset(.aa)) - 0.6) < 0.001)
        #expect(abs(entity.expression(for: .preset(.ih)) - 0.6) < 0.001)
    }

    /// The four look presets stay out of a `.vrma` as the eye bones do, gaze
    /// being look-at's to aim. A file carrying one drives nothing.
    @Test
    func testLookExpressionsAreLeftToLookAt() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        // Seed-san carries the look presets, so a retargeted one would show.
        entity.setExpression(value: 1, for: .preset(.lookRight))
        #expect(abs(entity.expression(for: .preset(.lookRight)) - 1) < 0.001)
        entity.setExpression(value: 0, for: .preset(.lookRight))

        try entity.playAnimation(try VRMAnimation(data: VRMASampleFixture.contestedExpressions()))
        entity.updateAnimations(deltaTime: 0.5)

        #expect(entity.expression(for: .preset(.lookRight)) == 0)
    }

    /// `.vrma` names the thumb chain in VRM 1.0 terms; a VRM 0.x model names
    /// the same bones proximal / intermediate / distal, one joint over.
    @Test
    func testThumbBonesRemapToTheVRM0Naming() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let vrm1Thumb = try #require(seedSan.humanoid.node(for: .leftThumbMetacarpal))
        let vrm1Rest = vrm1Thumb.transform.rotation
        try seedSan.playAnimation(fixture())
        #expect(abs(simd_dot(vrm1Thumb.transform.rotation, vrm1Rest)) < 0.999)

        let alicia = try VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let vrm0Thumb = try #require(alicia.humanoid.node(for: .leftThumbProximal))
        let vrm0Rest = vrm0Thumb.transform.rotation
        try alicia.playAnimation(fixture())
        #expect(abs(simd_dot(vrm0Thumb.transform.rotation, vrm0Rest)) < 0.999)
    }

    /// The eye bones stay out of a `.vrma` humanoid, gaze being look-at's to
    /// aim. A file mapping them poses nothing. Alicia is the bundled model with
    /// eye bones; Seed-san declares none.
    @Test
    func testEyeBonesAreLeftToLookAt() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let eyes = [Humanoid.Bones.leftEye, .rightEye].compactMap { entity.humanoid.node(for: $0) }
        #expect(eyes.count == 2)
        let rests = eyes.map(\.transform.rotation)

        // The fixture turns both eye bones 30° around +X.
        try entity.playAnimation(fixture())
        entity.updateAnimations(deltaTime: 1.0)

        for (eye, rest) in zip(eyes, rests) {
            #expect(abs(simd_dot(eye.transform.rotation, rest)) > 0.9999)
        }
    }

    /// The three-vrm sample `.vrma`, a real-world GLB whose skeleton rests with
    /// non-identity local rotations: its right-upper-arm channel rotates 90°
    /// around the bone's local +X, which that rest chain carries to the model's
    /// +Z, so the arm lifts sideways. At t = 1.5 `happy` reaches 1, and the
    /// look-at channel plays through unapplied.
    @Test
    func testTheThreeVRMSamplePlaysOnAVRM1Model() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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
    }

    /// The same sample on a VRM 0.x model: the arm swing turns around with the
    /// model, and the expression lands on the migrated `joy` blend shape.
    @Test
    func testTheThreeVRMSamplePlaysOnAVRM0Model() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let arm = try #require(entity.humanoid.node(for: .rightUpperArm))
        let rest = worldRotation(of: arm, in: entity)

        let controller = try entity.playAnimation(try VRMAnimation(withURL: VRMASampleAsset.test.url))
        entity.updateAnimations(deltaTime: 0.5)
        let swung = worldRotation(of: arm, in: entity) * rest.inverse
        #expect(abs(simd_dot(swung, simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 0, 1)))) > 0.999)

        controller.seek(to: 1.5)
        #expect(abs(entity.blendShape(for: .preset(.joy)) - 1.0) < 0.01)
    }

    /// The bundled CC0 walk cycle: a real full-body motion authored on neither
    /// bundled model's skeleton, so it exercises the retargeting broadly rather
    /// than one channel at a time.
    @Test(arguments: [VRMSampleAsset.seedSan, .aliciaSolid])
    func testTheWalkCycleDrivesTheWholeBodyOfEitherModel(model: VRMSampleAsset) throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: model.data).loadEntity()
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

    /// The walk cycle was authored with the hips 0.908 m up, and dips them to
    /// 82–88% of that. Retargeted, the hips must land in the same band of the
    /// target's own rest height rather than at the source's absolute metres.
    @Test
    func testTheWalkCycleScalesItsHipsToTheTargetModel() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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

    /// Seeking a finished VRM animation still poses the model: the controller
    /// owns its runtime, so both outlive the playback.
    @Test
    func testSeekingAFinishedVRMAnimationStillPosesTheModel() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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
    func testAKeptControllerDoesNotRetainTheAnimatedModel() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        weak var loaded: VRMEntity?
        var controller: GLTFAnimationPlaybackController?
        do {
            let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
            loaded = entity
            controller = try entity.playAnimation(fixture())
        }

        #expect(controller != nil)
        #expect(loaded == nil)
    }

    /// Two animations driving the same expression: the one started last owns it
    /// on every frame, not only on the frame it takes over.
    @Test
    func testTheLastStartedAnimationKeepsOwningASharedExpression() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

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
    func testAPausedAnimationKeepsHoldingItsTargets() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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

    /// `upperChest` is optional, and neither bundled model has one. Its rotation
    /// must still reach the model, through the bones that inherited its
    /// children, rather than be dropped with the bone.
    @Test(arguments: [VRMSampleAsset.seedSan, .aliciaSolid])
    func testAnOptionalBoneTheModelLacksRotatesItsChildrenInstead(model: VRMSampleAsset) throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: model.data).loadEntity()
        #expect(entity.humanoid.node(for: .upperChest) == nil)
        let bones = try [Humanoid.Bones.neck, .leftShoulder, .rightShoulder].map {
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

    /// A `.vrma` is retargeted without ever being loaded as a scene, so a
    /// document no model could be loaded from is rejected where its hierarchy
    /// is built.
    @Test
    func testAnAnimationWithoutANodeHierarchyIsRejected() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let animation = try VRMAnimation(data: VRMASampleFixture.hipsWithTwoParents())
        #expect(throws: VRMError.self) { try entity.playAnimation(animation) }
    }

    @Test
    func testACloneCannotPlayVRMAnimations() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let clone = entity.clone(recursive: true)
        let animation = try fixture()
        #expect(throws: VRMError.self) { try clone.playAnimation(animation) }
    }
}
#endif
