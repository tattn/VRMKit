import Foundation
import SIMDCompat
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMKitRuntime

/// glTF and VRM animations play on a model read into an asset, with no renderer: the pose
/// moves, and what the animations set beyond it comes out as values.
@Suite
struct GLTFAnimationPlayerTests {
    private func gltfPlayer(_ fixture: GLTFSampleAsset) async throws -> (GLTFAsset, GLTFAnimationPlayer, GLTFAnimationRuntime) {
        let asset = try await GLTFAsset.load(document: try GLTFDocument(withURL: fixture.url))
        let runtime = try GLTFAnimationRuntime(
            animation: try asset.document.gltf.load(\.animations, at: 0),
            decoder: GLTFAnimationDecoder(document: asset.document),
            posedNodes: Set(asset.nodes.indices),
            morphTargetCounts: asset.meshIndicesByNode.mapValues { asset.meshes[$0].geometry.blendShapeTargetCount }
        )
        return (asset, GLTFAnimationPlayer(pose: asset.makePose()), runtime)
    }

    @Test
    func testAGLTFAnimationPosesItsNodes() async throws {
        let (asset, player, runtime) = try await gltfPlayer(.animatedTriangle)
        let duration = GLTFAnimationDecoder(document: asset.document).duration(of: asset.document.gltf.animations[0])
        let controller = player.start(GLTFAnimation(index: 0, name: nil, duration: duration),
                                      runtime: runtime, ownsRuntime: false, loops: false, speed: 1)
        let rest = player.pose.localTransform(ofNode: 0).rotation

        player.advance(deltaTime: duration / 4)
        #expect(abs(simd_dot(player.pose.localTransform(ofNode: 0).rotation.vector, rest.vector)) < 0.999)

        var finished = false
        player.didFinish = { finished = true }
        controller.stop()
        #expect(finished)
        #expect(!player.isPlaying)
    }

    @Test
    func testAWeightsChannelSetsTheMorphWeightsOfTheNodesMesh() async throws {
        let (_, player, runtime) = try await gltfPlayer(.animatedMorphCube)
        var weights: [Int: [Float]] = [:]
        player.didApply = { weights.merge($0.morphWeights) { $1 } }
        let controller = player.start(GLTFAnimation(index: 0, name: nil, duration: 1),
                                      runtime: runtime, ownsRuntime: false, loops: true, speed: 1)

        controller.seek(to: 0.5)
        let node = try #require(weights[0])
        #expect(node.count == 2)
    }

    /// A `.vrma` retargets onto the humanoid of the model it plays on.
    @Test
    func testAVRMAnimationRetargetsOntoTheHumanoid() async throws {
        let vrm = try VRM(data: VRMSampleAsset.seedSan.data)
        let asset = try await GLTFAsset.load(vrm: vrm)
        let humanoid = Dictionary(uniqueKeysWithValues: HumanoidBone.allCases.compactMap { bone in
            vrm.nodeIndex(of: bone).map { (bone, $0) }
        })
        let model = VRMAnimationRuntime.Model(facesNegativeZ: vrm.forwardDirection.z < 0,
                                              humanoidNodes: humanoid,
                                              restPose: try GLTFRestPose(nodes: vrm.document.gltf.nodes))
        let runtime = try VRMAnimationRuntime(animation: try VRMAnimation(withURL: VRMASampleAsset.walk.url),
                                              animationIndex: 0,
                                              model: model)
        let player = GLTFAnimationPlayer(pose: asset.makePose())
        let hips = try #require(humanoid[.hips])
        let rest = player.pose.localTransform(ofNode: hips)

        _ = player.start(GLTFAnimation(index: 0, name: runtime.name, duration: runtime.duration),
                         runtime: runtime, ownsRuntime: true, loops: true, speed: 1)
        player.advance(deltaTime: runtime.duration / 3)

        let moved = player.pose.localTransform(ofNode: hips)
        #expect(moved.translation != rest.translation || moved.rotation != rest.rotation)
    }
}
