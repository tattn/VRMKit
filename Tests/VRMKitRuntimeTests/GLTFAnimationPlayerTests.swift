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
}
