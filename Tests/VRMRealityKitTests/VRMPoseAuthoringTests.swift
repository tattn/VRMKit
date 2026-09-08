#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Writing the pose a model holds as a `.vrma`, and playing it back.
@Suite
@MainActor
struct VRMPoseAuthoringTests {
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func worldRotation(of entity: Entity, in root: Entity) -> simd_quatf {
        Transform(matrix: entity.transformMatrix(relativeTo: root)).rotation
    }

    /// Poses a loaded model by hand: the left upper arm raised and the hips shifted.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func pose(_ entity: VRMEntity) throws {
        let arm = try #require(entity.humanoid.node(for: .leftUpperArm))
        arm.transform.rotation *= simd_quatf(angle: -.pi / 3, axis: SIMD3<Float>(0, 0, 1))
        let hips = try #require(entity.humanoid.node(for: .hips))
        hips.transform.translation += SIMD3<Float>(0.05, -0.1, 0.02)
    }

    /// A pose written off one model and played back on a fresh copy of it lands where
    /// it was: the skeleton is the model's own, so the retarget is the identity.
    @Test(arguments: [VRMSampleAsset.seedSan, .aliciaSolid])
    func testThePoseRoundTripsOntoTheSameModel(asset: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let posed = try await VRMEntityLoader(withData: asset.data, shaders: []).loadEntity()
        try pose(posed)

        let data = try posed.poseAnimationData(name: "held", duration: 1)

        let animation = try VRMAnimation(data: data)
        #expect(animation.humanoid?.humanBones["hips"] != nil)
        let played = try await VRMEntityLoader(withData: asset.data, shaders: []).loadEntity()
        let controller = try played.playAnimation(animation)
        #expect(controller.animation.name == "held")
        #expect(controller.animation.duration.isApproximatelyEqual(to: 1))
        played.updateAnimations(deltaTime: 0.5)

        for bone in [HumanoidBone.leftUpperArm, .hips, .head, .rightHand] {
            let expected = try #require(posed.humanoid.node(for: bone))
            let actual = try #require(played.humanoid.node(for: bone))
            let delta = worldRotation(of: actual, in: played) * worldRotation(of: expected, in: posed).inverse
            #expect(abs(delta.real) > 0.9999, "\(bone) turned away from the pose")
        }
        let expectedHips = try #require(posed.humanoid.node(for: .hips)).position(relativeTo: posed)
        let actualHips = try #require(played.humanoid.node(for: .hips)).position(relativeTo: played)
        #expect(actualHips.isApproximatelyEqual(to: expectedHips, tolerance: 0.002))
    }

    /// Every rigged bone gets a rotation track, and the hips a translation track, so the
    /// clip states the whole body.
    @Test
    func testEveryHumanoidBoneIsWritten() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()

        let animation = try VRMAnimation(data: try entity.poseAnimationData())

        let bones = entity.vrm.boneNodes.count
        #expect(animation.humanoid?.humanBones.count == bones)
        let channels = try #require(animation.document.gltf.animations.first?.channels)
        #expect(channels.filter { $0.target.targetPath == .rotation }.count == bones)
        #expect(channels.filter { $0.target.targetPath == .translation }.count == 1)
    }

    /// The expressions the model wears come along, each on a node of its own, and land
    /// on a fresh copy at the weight they were written at; the ones it does not wear are
    /// left unstated, so nothing about them is forced on playback.
    @Test(arguments: [VRMSampleAsset.seedSan, .aliciaSolid])
    func testTheExpressionsWornAreWrittenAndTheRestLeftUnstated(asset: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let posed = try await VRMEntityLoader(withData: asset.data, shaders: []).loadEntity()
        posed.setExpressions([.preset(.happy): 0.75, .preset(.aa): 0.4])

        let animation = try VRMAnimation(data: try posed.poseAnimationData(duration: 1))

        let expressions = try #require(animation.expressions)
        #expect(Set(expressions.preset?.keys.map { $0 } ?? []) == ["happy", "aa"])
        #expect(expressions.custom == nil)
        // The expression channels come last, in the order of their nodes.
        let channels = try #require(animation.document.gltf.animations.first?.channels)
        let expressionChannels = channels.suffix(2).compactMap(\.target.node)
        #expect(expressionChannels == expressionChannels.sorted())
        #expect(Set(expressionChannels) == Set([expressions.preset?["happy"]?.node, expressions.preset?["aa"]?.node].compactMap { $0 }))
        let played = try await VRMEntityLoader(withData: asset.data, shaders: []).loadEntity()
        _ = try played.playAnimation(animation)
        played.updateAnimations(deltaTime: 0.5)
        // Read back through the model, since a binary expression holds 0 or 1 whatever
        // weight it was given.
        for key in [ExpressionKey.preset(.happy), .preset(.aa)] {
            #expect(Double(played.expression(for: key)).isApproximatelyEqual(to: Double(posed.expression(for: key))))
            #expect(played.expression(for: key) > 0)
        }
        #expect(played.expression(for: .preset(.blink)) == 0)

        // A face wearing nothing writes no expressions at all.
        let plain = try await VRMEntityLoader(withData: asset.data, shaders: []).loadEntity()
        #expect(try VRMAnimation(data: try plain.poseAnimationData()).expressions == nil)
    }

    /// Zero duration writes a single keyframe rather than two at the same time, which
    /// glTF forbids.
    @Test
    func testZeroDurationWritesOneKeyframe() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()

        let animation = try VRMAnimation(data: try entity.poseAnimationData(duration: 0))

        let controller = try entity.playAnimation(animation)
        #expect(controller.animation.duration == 0)
        #expect(throws: VRMError.self) {
            try entity.poseAnimationData(duration: -1)
        }
    }
}
#endif
