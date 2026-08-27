#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Plays the Khronos CC0 animation fixtures through the glTF animation
/// runtime, driving the tick directly instead of through a rendering scene.
@Suite
@MainActor
struct GLTFAnimationPlaybackTests {
    @Test
    func testAnimationMetadataIsLazyAndIndexBased() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedTriangle)

        let animations = entity.animations
        #expect(animations.count == 1)
        #expect(animations[0].index == 0)
        #expect(animations[0].name == nil)
        #expect(animations[0].duration.isApproximatelyEqual(to: 1.0))
        // Unnamed animations are only addressable by index.
        #expect(entity.animations(named: "walk").isEmpty)
    }

    /// A controller outlives its playback whenever the caller keeps it, so it
    /// must hold neither the entity nor the runtime posing the entity graph.
    @Test
    func testAKeptControllerDoesNotRetainTheAnimatedGraph() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        weak var loaded: GLTFEntity?
        weak var animatedNode: Entity?
        var controller: GLTFAnimationPlaybackController?
        do {
            let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedTriangle)
            loaded = entity
            let node: Entity = try #require(entity.entity(forNodeAt: 0))
            animatedNode = node
            controller = try entity.playAnimation(at: 0)
            controller?.stop()
        }

        #expect(controller != nil)
        #expect(loaded == nil)
        #expect(animatedNode == nil)
    }

    @Test
    func testRotationChannelDrivesTheNodeTransform() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedTriangle)
        let node = try #require(entity.entity(forNodeAt: 0))

        let controller = try entity.playAnimation(at: 0)
        // Keyframe 0.25 is exactly a 90° rotation around +z.
        entity.updateAnimations(deltaTime: 0.25)
        #expect(controller.time.isApproximatelyEqual(to: 0.25))
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        #expect(abs(simd_dot(node.transform.rotation, quarter)) > 0.999)

        // Between keyframes 0 and 0.25 the rotation slerps: 45° at t = 0.125.
        controller.seek(to: 0.125)
        let eighth = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1))
        #expect(abs(simd_dot(node.transform.rotation, eighth)) > 0.999)
    }

    @Test
    func testWeightsChannelDrivesBlendShapeWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.simpleMorph)
        let modelEntity = try #require(entity.morphBindings[0]?.modelEntities.first)

        // SimpleMorph: 2 targets, keyframes at t = 0...4 with weights
        // (0,0) (0,1) (1,1) (1,0) (0,0); mesh.weights started them at 0.5.
        let controller = try entity.playAnimation(at: 0)
        entity.updateAnimations(deltaTime: 1.0)
        var weights = try #require(modelEntity.blendWeights.first)
        #expect(weights[0].isApproximatelyEqual(to: 0))
        #expect(weights[1].isApproximatelyEqual(to: 1))

        // Halfway between keyframes 1 and 2 both targets interpolate.
        controller.seek(to: 1.5)
        weights = try #require(modelEntity.blendWeights.first)
        #expect(weights[0].isApproximatelyEqual(to: 0.5))
        #expect(weights[1].isApproximatelyEqual(to: 1))
    }

    @Test
    func testJointAnimationRefreshesTheSkeletalPose() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.simpleSkin)
        let binding = try #require(entity.skinBindings.first)

        func pose() throws -> JointTransforms {
            let component = try #require(binding.modelEntity.components[SkeletalPosesComponent.self])
            return try #require(component.poses.default?.jointTransforms)
        }

        let initialPose = try pose()
        try entity.playAnimation(at: 0)
        // SimpleSkin's joint node 2 is rotated 90° around +z at t = 1.
        entity.updateAnimations(deltaTime: 1.0)
        let animatedPose = try pose()
        let changed = zip(initialPose, animatedPose).contains { before, after in
            abs(simd_dot(before.rotation, after.rotation)) < 0.999
        }
        #expect(changed)
    }

    @Test
    func testInterpolationTestDecodesAndPlaysEveryAnimation() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.interpolationTest)

        // 9 animations covering LINEAR / STEP / CUBICSPLINE for rotation and
        // translation; every one must decode and evaluate without throwing.
        #expect(entity.animations.count == 9)
        for animation in entity.animations {
            #expect(animation.duration > 0, "animation \(animation.index)")
            let controller = try entity.playAnimation(at: animation.index, loops: true)
            entity.updateAnimations(deltaTime: animation.duration * 0.4)
            controller.stop()
        }
    }

    @Test
    func testNonLoopingPlaybackCompletesAndHoldsTheFinalPose() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedTriangle)
        let node = try #require(entity.entity(forNodeAt: 0))

        let controller = try entity.playAnimation(at: 0)
        #expect(entity.components.has(GLTFAnimationPlaybackComponent.self))
        entity.updateAnimations(deltaTime: 5)

        #expect(controller.isComplete)
        #expect(controller.time.isApproximatelyEqual(to: 1.0))
        // The final keyframe is identity; the pose holds there.
        #expect(abs(node.transform.rotation.real).isApproximatelyEqual(to: 1, tolerance: 0.001))
        // A completed entity leaves the animation system's query.
        #expect(!entity.components.has(GLTFAnimationPlaybackComponent.self))
    }

    @Test
    func testLoopingPlaybackWrapsAndPauseHolds() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedTriangle)

        let controller = try entity.playAnimation(at: 0, loops: true, speed: 2)
        entity.updateAnimations(deltaTime: 0.6) // 1.2s of animation time wraps to 0.2
        #expect(!controller.isComplete)
        #expect(controller.time.isApproximatelyEqual(to: 0.2, tolerance: 0.001))

        controller.isPaused = true
        entity.updateAnimations(deltaTime: 10)
        #expect(controller.time.isApproximatelyEqual(to: 0.2, tolerance: 0.001))

        controller.stop()
        #expect(!entity.components.has(GLTFAnimationPlaybackComponent.self))
    }

    /// A NaN or infinite rate would put NaN through every pose it drives, so the
    /// controller keeps the rate it had.
    @Test
    func testANonFiniteSpeedOrSeekIsRefused() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedTriangle)

        let controller = try entity.playAnimation(at: 0, loops: true, speed: .nan)
        #expect(controller.speed == 1)

        controller.speed = .infinity
        #expect(controller.speed == 1)

        entity.updateAnimations(deltaTime: 0.5)
        #expect(controller.time.isApproximatelyEqual(to: 0.5, tolerance: 0.001))

        controller.seek(to: .nan)
        #expect(controller.time.isApproximatelyEqual(to: 0.5, tolerance: 0.001))
    }

    /// A CUBICSPLINE rotation output interleaves in-tangent / value / out-tangent,
    /// and normalizing the tangents would rescale the curve's slope.
    @Test
    func testCubicSplineRotationKeepsItsTangentsUnnormalized() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let decoder = GLTFAnimationDecoder(document: try GLTFDocument(data: splineRotationFixture()))
        let quaternions = try decoder.quaternions(at: 1, interpolation: .CUBICSPLINE)

        // Keyframe 0: in-tangent (0,0,0,0), value identity, out-tangent (0,0,4,0).
        #expect(quaternions.count == 6)
        #expect(simd_length(quaternions[0].vector).isApproximatelyEqual(to: 0))
        #expect(simd_length(quaternions[1].vector).isApproximatelyEqual(to: 1))
        #expect(quaternions[2].vector.isApproximatelyEqual(to: SIMD4<Float>(0, 0, 4, 0)))
        // The same accessor read as LINEAR normalizes every element instead.
        let linearDecoder = GLTFAnimationDecoder(document: try GLTFDocument(data: splineRotationFixture()))
        let asLinear = try linearDecoder.quaternions(at: 1, interpolation: .LINEAR)
        #expect(simd_length(asLinear[2].vector).isApproximatelyEqual(to: 1))
    }

    /// Two *different* animations driving the same morph targets: the one started
    /// last wins, and stopping it lets the first one drive the targets again.
    @Test
    func testASecondWeightsAnimationTakesOverAndReleasesTheTargets() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withData: twoWeightAnimationsFixture()).loadEntity()
        let modelEntity = try #require(entity.morphBindings[0]?.modelEntities.first)
        func weight() throws -> Float {
            try #require(modelEntity.blendWeights.first?.first)
        }

        let first = try entity.playAnimation(at: 0, loops: true)   // holds 0.25
        entity.updateAnimations(deltaTime: 0)
        #expect(try weight().isApproximatelyEqual(to: 0.25))

        let second = try entity.playAnimation(at: 1, loops: true)  // holds 0.75
        entity.updateAnimations(deltaTime: 0)
        #expect(try weight().isApproximatelyEqual(to: 0.75))

        second.stop()
        entity.updateAnimations(deltaTime: 0)
        #expect(try weight().isApproximatelyEqual(to: 0.25))
        #expect(!first.isComplete)
    }

    /// Seeking an animation another one outranks must not let it take the target
    /// over until the next frame: the later-started animation still wins.
    @Test
    func testSeekingAnOutrankedAnimationDoesNotTakeOverTheTarget() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withData: twoWeightAnimationsFixture()).loadEntity()
        let modelEntity = try #require(entity.morphBindings[0]?.modelEntities.first)
        func weight() throws -> Float {
            try #require(modelEntity.blendWeights.first?.first)
        }

        let first = try entity.playAnimation(at: 0, loops: true)   // holds 0.25
        try entity.playAnimation(at: 1, loops: true)               // holds 0.75, started last
        first.seek(to: 0.5)
        #expect(try weight().isApproximatelyEqual(to: 0.75))

        // The seek still poses the model once nothing outranks it any more.
        entity.stopAnimations()
        first.seek(to: 0.5)
        #expect(try weight().isApproximatelyEqual(to: 0.25))
    }

    /// One morph target, two STEP animations holding different constant
    /// weights on the same node.
    private func twoWeightAnimationsFixture() -> Data {
        var buffer = Data(littleEndianFloats: [0, 0, 0, 1, 0, 0, 0, 1, 0])   // POSITION
        let targetOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0, 1, 0, 0, 1, 0, 0, 1, 0])) // morph target offsets
        let timesOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0, 1]))
        let weightsAOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0.25, 0.25]))
        let weightsBOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0.75, 0.75]))

        let json = """
        {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "targets": [{"POSITION": 1}]}]}],
            "animations": [
                {"channels": [{"sampler": 0, "target": {"node": 0, "path": "weights"}}],
                 "samplers": [{"input": 2, "interpolation": "STEP", "output": 3}]},
                {"channels": [{"sampler": 0, "target": {"node": 0, "path": "weights"}}],
                 "samplers": [{"input": 2, "interpolation": "STEP", "output": 4}]}
            ],
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": 36},
                {"buffer": 0, "byteOffset": \(targetOffset), "byteLength": 36},
                {"buffer": 0, "byteOffset": \(timesOffset), "byteLength": 8},
                {"buffer": 0, "byteOffset": \(weightsAOffset), "byteLength": 8},
                {"buffer": 0, "byteOffset": \(weightsBOffset), "byteLength": 8}
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
                {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [0, 1, 0]},
                {"bufferView": 2, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]},
                {"bufferView": 3, "componentType": 5126, "count": 2, "type": "SCALAR"},
                {"bufferView": 4, "componentType": 5126, "count": 2, "type": "SCALAR"}
            ]
        }
        """
        return Data(json.utf8)
    }

    /// A one-node, one-morph-target glTF whose only animation drives `weights`
    /// with the given keyframe times and STEP output values.
    private func weightAnimationFixture(times: [Float], weights: [Float]) -> Data {
        var buffer = Data(littleEndianFloats: [0, 0, 0, 1, 0, 0, 0, 1, 0])   // POSITION
        let targetOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0, 1, 0, 0, 1, 0, 0, 1, 0])) // morph target offsets
        let timesOffset = buffer.count
        buffer.append(Data(littleEndianFloats: times))
        let weightsOffset = buffer.count
        buffer.append(Data(littleEndianFloats: weights))

        let json = """
        {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "targets": [{"POSITION": 1}]}]}],
            "animations": [
                {"channels": [{"sampler": 0, "target": {"node": 0, "path": "weights"}}],
                 "samplers": [{"input": 2, "interpolation": "STEP", "output": 3}]}
            ],
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": 36},
                {"buffer": 0, "byteOffset": \(targetOffset), "byteLength": 36},
                {"buffer": 0, "byteOffset": \(timesOffset), "byteLength": \(times.count * 4)},
                {"buffer": 0, "byteOffset": \(weightsOffset), "byteLength": \(weights.count * 4)}
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
                {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [0, 1, 0]},
                {"bufferView": 2, "componentType": 5126, "count": \(times.count), "type": "SCALAR", "min": [\(times.min() ?? 0)], "max": [\(times.max() ?? 0)]},
                {"bufferView": 3, "componentType": 5126, "count": \(weights.count), "type": "SCALAR"}
            ]
        }
        """
        return Data(json.utf8)
    }

    /// glTF sizes a `weights` output by keyframes × morph targets, so one that
    /// merely divides evenly by the keyframe count is still malformed.
    @Test
    func testWeightsOutputMustMatchTheMorphTargetCount() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // One morph target and two keyframes, but four weights.
        let mismatched = try await GLTFEntityLoader(withData: weightAnimationFixture(times: [0, 1],
                                                                              weights: [0, 0, 1, 1])).loadEntity()
        #expect(throws: VRMError.self) { try mismatched.playAnimation(at: 0) }

        let exact = try await GLTFEntityLoader(withData: weightAnimationFixture(times: [0, 1],
                                                                         weights: [0, 1])).loadEntity()
        #expect(try exact.playAnimation(at: 0).isComplete == false)
    }

    /// A zero-length animation has a single pose, so looping it completes with
    /// that pose applied instead of ticking the entity forever.
    @Test
    func testZeroDurationLoopAppliesItsPoseAndCompletes() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withData: weightAnimationFixture(times: [0], weights: [0.5])).loadEntity()
        let modelEntity = try #require(entity.morphBindings[0]?.modelEntities.first)

        let controller = try entity.playAnimation(at: 0, loops: true)
        #expect(controller.animation.duration == 0)

        entity.updateAnimations(deltaTime: 1.0 / 60)
        #expect(try #require(modelEntity.blendWeights.first?.first).isApproximatelyEqual(to: 0.5))
        #expect(controller.isComplete)
        // With nothing left to advance, the entity leaves the animation system.
        #expect(!entity.components.has(GLTFAnimationPlaybackComponent.self))
    }

    /// A controller stays usable after it finishes: seeking it still poses the
    /// model, including the skinned meshes.
    @Test
    func testSeekingAFinishedControllerStillUpdatesTheSkinPose() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.simpleSkin)
        let binding = try #require(entity.skinBindings.first)
        func pose() throws -> JointTransforms {
            let component = try #require(binding.modelEntity.components[SkeletalPosesComponent.self])
            return try #require(component.poses.default?.jointTransforms)
        }

        let controller = try entity.playAnimation(at: 0)
        entity.updateAnimations(deltaTime: 99)
        #expect(controller.isComplete)
        let restPose = try pose()

        controller.seek(to: 1)  // joint node 2 is rotated 90° at t = 1
        let seekedPose = try pose()
        let changed = zip(restPose, seekedPose).contains { before, after in
            abs(simd_dot(before.rotation, after.rotation)) < 0.999
        }
        #expect(changed)
    }

    /// A held pose must not re-solve the skeleton: paused playback, a zero speed
    /// and a STEP track between keyframes all leave the joints in place.
    @Test
    func testHeldPosesDoNotReportMovedJoints() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.animatedTriangle)
        let controller = try entity.playAnimation(at: 0, loops: true)

        // A real advance moves the node...
        #expect(controller.advance(deltaTime: 0.1))
        // ...but re-applying the same time does not.
        #expect(!controller.advance(deltaTime: 0))

        controller.isPaused = true
        #expect(!controller.advance(deltaTime: 0.5))
        controller.isPaused = false

        controller.speed = 0
        #expect(!controller.advance(deltaTime: 0.5))
    }

    @Test
    func testNegativeSpeedPlaysBackwardsFromTheEnd() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.animatedTriangle)

        let controller = try entity.playAnimation(at: 0, speed: -1)
        #expect(controller.time.isApproximatelyEqual(to: 1.0))
        entity.updateAnimations(deltaTime: 0.25)
        #expect(!controller.isComplete)
        #expect(controller.time.isApproximatelyEqual(to: 0.75))

        entity.updateAnimations(deltaTime: 1)
        #expect(controller.isComplete)
        #expect(controller.time.isApproximatelyEqual(to: 0))
    }

    /// A rotation sampler with two CUBICSPLINE keyframes: identity at t = 0
    /// with a long out-tangent, identity at t = 1 with a zero in-tangent.
    private func splineRotationFixture() -> Data {
        var buffer = Data(littleEndianFloats: [0, 1])                    // input times
        let outputOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [
            0, 0, 0, 0,   0, 0, 0, 1,   0, 0, 4, 0,   // keyframe 0: a, v, b
            0, 0, 0, 0,   0, 0, 0, 1,   0, 0, 0, 0    // keyframe 1: a, v, b
        ]))
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": 8},
                {"buffer": 0, "byteOffset": \(outputOffset), "byteLength": 96}
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1]},
                {"bufferView": 1, "componentType": 5126, "count": 6, "type": "VEC4"}
            ]
        }
        """
        return Data(json.utf8)
    }

    /// One accessor of a hand-written animation sampler, described exactly as it
    /// should reach the loader, storage the spec forbids included.
    private struct SamplerStorage {
        let componentType: Int
        let type: String
        let count: Int
        let bytes: Data
        var normalized = false
    }

    /// A one-node glTF whose only animation drives `path` through the two given
    /// sampler accessors.
    private func samplerFixture(path: String, input: SamplerStorage, output: SamplerStorage) -> Data {
        var buffer = input.bytes
        buffer.append(contentsOf: [UInt8](repeating: 0, count: (4 - buffer.count % 4) % 4))
        let outputOffset = buffer.count
        buffer.append(output.bytes)
        func accessor(_ storage: SamplerStorage, bufferView: Int) -> String {
            """
            {"bufferView": \(bufferView), "componentType": \(storage.componentType), "count": \(storage.count),             "type": "\(storage.type)", "normalized": \(storage.normalized)}
            """
        }
        let json = """
        {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{}],
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": \(input.bytes.count)},
                {"buffer": 0, "byteOffset": \(outputOffset), "byteLength": \(output.bytes.count)}
            ],
            "accessors": [\(accessor(input, bufferView: 0)), \(accessor(output, bufferView: 1))],
            "animations": [{
                "samplers": [{"input": 0, "interpolation": "LINEAR", "output": 1}],
                "channels": [{"sampler": 0, "target": {"node": 0, "path": "\(path)"}}]
            }]
        }
        """
        return Data(json.utf8)
    }

    /// Two identity rotation keyframes at t = 0 and t = 1, as FLOAT.
    private var floatTimes: SamplerStorage {
        SamplerStorage(componentType: 5126, type: "SCALAR", count: 2, bytes: Data(littleEndianFloats: [0, 1]))
    }

    private var floatRotations: SamplerStorage {
        SamplerStorage(componentType: 5126, type: "VEC4", count: 2,
                       bytes: Data(littleEndianFloats: [0, 0, 0, 1, 0, 0, 0, 1]))
    }

    /// Identity rotations as normalized SHORT, which the spec allows.
    private var shortRotationBytes: Data {
        var bytes = Data()
        bytes.appendLittleEndian([0, 0, 0, 32767, 0, 0, 0, 32767])
        return bytes
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @MainActor
    private func loadAnimated(path: String, input: SamplerStorage, output: SamplerStorage) async throws -> GLTFEntity {
        try await GLTFEntityLoader(withData: samplerFixture(path: path, input: input, output: output)).loadEntity()
    }

    /// The spec fixes a sampler input to FLOAT scalars starting at or after zero.
    /// `PackedAccessor` converts integer components to Float just as happily, so
    /// only the decoder's own check keeps a malformed input out.
    @Test
    func testAnimationInputMustBeNonNegativeFloats() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        var integerTimes = Data()
        integerTimes.appendLittleEndian([0, 1])
        let integer = try await loadAnimated(path: "rotation",
                                             input: SamplerStorage(componentType: 5123, type: "SCALAR",
                                                                   count: 2, bytes: integerTimes),
                                             output: floatRotations)
        #expect(throws: VRMError.self) { try integer.playAnimation(at: 0) }

        let negative = try await loadAnimated(path: "rotation",
                                              input: SamplerStorage(componentType: 5126, type: "SCALAR", count: 2,
                                                                    bytes: Data(littleEndianFloats: [-1, 1])),
                                              output: floatRotations)
        #expect(throws: VRMError.self) { try negative.playAnimation(at: 0) }
    }

    /// A rotation is a unit quantity, so the spec also stores it as normalized
    /// integers. A translation is not, and neither is an unnormalized rotation.
    @Test
    func testAnimationOutputComponentTypeFollowsTheTargetPath() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let normalized = try await loadAnimated(path: "rotation",
                                                input: floatTimes,
                                                output: SamplerStorage(componentType: 5122, type: "VEC4", count: 2,
                                                                       bytes: shortRotationBytes, normalized: true))
        let controller = try normalized.playAnimation(at: 0)
        #expect(!controller.isComplete)

        let unnormalized = try await loadAnimated(path: "rotation",
                                                  input: floatTimes,
                                                  output: SamplerStorage(componentType: 5122, type: "VEC4", count: 2,
                                                                         bytes: shortRotationBytes))
        #expect(throws: VRMError.self) { try unnormalized.playAnimation(at: 0) }

        var shortVectors = Data()
        shortVectors.appendLittleEndian([0, 0, 0, 0, 0, 0])
        let translation = try await loadAnimated(path: "translation",
                                                 input: floatTimes,
                                                 output: SamplerStorage(componentType: 5122, type: "VEC3", count: 2,
                                                                        bytes: shortVectors, normalized: true))
        #expect(throws: VRMError.self) { try translation.playAnimation(at: 0) }
    }

    /// A rotation or a weight normalizes bytes and shorts only: UNSIGNED_INT is
    /// reserved for primitive indices, and normalizing it is forbidden outright.
    @Test
    func testUnsignedIntAnimationOutputIsRejectedEvenWhenNormalized() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        var intRotations = Data()
        intRotations.appendLittleEndian(unsignedInts: [0, 0, 0, .max, 0, 0, 0, .max])
        let rotation = try await loadAnimated(path: "rotation",
                                              input: floatTimes,
                                              output: SamplerStorage(componentType: 5125, type: "VEC4", count: 2,
                                                                     bytes: intRotations, normalized: true))
        #expect(throws: VRMError.self) { try rotation.playAnimation(at: 0) }
    }

    /// At most one channel of an animation may drive a given (node, path): a
    /// file with two leaves the winner to chance, so it has to be rejected.
    @Test
    func testDuplicateChannelTargetsAreRejected() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.animatedTriangle) { json in
            var animations = json.objects("animations")
            guard !animations.isEmpty else { throw GLBRewriter.Error.invalidJSON }
            let channels = animations[0].objects("channels")
            guard let channel = channels.first else { throw GLBRewriter.Error.invalidJSON }
            animations[0]["channels"] = .objects(channels + [channel])
            json["animations"] = .objects(animations)
        }
        let entity = try await loader.loadEntity()

        // The metadata pass does not read channels, so only playback rejects it.
        #expect(entity.animations.count == 1)
        #expect(throws: VRMError.self) { try entity.playAnimation(at: 0) }
    }

    /// A channel targets a node of the document, and an animated node states
    /// its transform as TRS rather than as a `matrix`.
    @Test
    func testAnimationChannelTargetsAreValidated() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let outOfRange = try await TestSupport.loader(.animatedTriangle) { json in
            var animations = json.objects("animations")
            guard !animations.isEmpty else { throw GLBRewriter.Error.invalidJSON }
            var channels = animations[0].objects("channels")
            guard !channels.isEmpty, var target = channels[0].object("target") else {
                throw GLBRewriter.Error.invalidJSON
            }
            target["node"] = 1
            channels[0]["target"] = .object(target)
            animations[0]["channels"] = .objects(channels)
            json["animations"] = .objects(animations)
        }.loadEntity()
        #expect(throws: VRMError.self) { try outOfRange.playAnimation(at: 0) }

        let matrixNode = try await TestSupport.loader(.animatedTriangle) { json in
            var nodes = json.objects("nodes")
            guard !nodes.isEmpty else {
                throw GLBRewriter.Error.invalidJSON
            }
            nodes[0]["rotation"] = nil
            nodes[0]["matrix"] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            json["nodes"] = .objects(nodes)
        }.loadEntity()
        #expect(throws: VRMError.self) { try matrixNode.playAnimation(at: 0) }
    }

    @Test
    func testVRMEntityInheritsTheAnimationAPI() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // The VRM fixtures carry no glTF animations; the API still answers.
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        #expect(vrmEntity.animations.isEmpty)
        #expect(throws: VRMError.self) {
            try vrmEntity.playAnimation(at: 0)
        }
    }
}
#endif
