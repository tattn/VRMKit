import VRMKit
@testable import VRMSceneKit
import SceneKit
import simd
import Testing

@Suite
struct VRM1SceneLoaderTests {

    func vrmLoader() throws -> VRMSceneLoader {
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        return try VRMSceneLoader(withURL: url)
    }

    @Test
    func testLoadVRM1() throws {
        let vrmLoader = try vrmLoader()
        let vrm = vrmLoader.vrm
        guard case .v1(let vrm1) = vrm else {
            throw VRMError.dataInconsistent("Expected VRM1")
        }
        let gltf = vrm1.gltf.jsonData

        #expect(vrm1.meta.name == "Seed-san")
        #expect(gltf.asset.version == "2.0")
        let buffers = try #require(gltf.buffers, "GLTF buffers should not be nil")
        #expect(buffers.map(\.byteLength) == [10783033])
        let bufferViews = try #require(gltf.bufferViews, "GLTF bufferViews should not be nil")
        #expect(bufferViews.count == 404)
        #expect(gltf.scene == 0)
        let scenes = try #require(gltf.scenes, "GLTF scenes should not be nil")
        #expect(scenes.map(\.nodes).map(\.?.count) == [7])

        let loadedThumbnail = try vrmLoader.loadThumbnail()
        let thumbnail = try #require(loadedThumbnail, "Thumbnail should be loadable and not nil.")
        #expect(thumbnail.size == CGSize(width: 512, height: 512))
    }

    @Test
    func testBufferAccess() throws {
        let vrmLoader = try vrmLoader()
        let result = try vrmLoader.bufferView(withBufferViewIndex: 0)
        #expect(result.stride == nil)
        #expect(result.bufferView.count == 93840)
    }

    @Test
    func testVRM1NativeExpressionBindingsUseNodes() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let vrmNode = scene.vrmNode

        #expect(vrmNode.expressionClips.count == 18)
        let happyBinding = try #require(vrmNode.expressionClips[.preset(.happy)]?.values.first)
        #expect(happyBinding.mesh === (try vrmLoader.node(withNodeIndex: 2)))
        #expect(vrmNode.expressionClips[.preset(.aa)]?.values.first?.index == 25)

        vrmNode.setExpression(value: 0.42, for: .preset(.aa))
        #expect(abs(vrmNode.expression(for: .preset(.aa)) - 0.42) < 0.001)
        #expect(abs(vrmNode.blendShape(for: .preset(.a)) - 0.42) < 0.001)
    }

    @Test
    func testVRM1FirstPersonAnnotationsUseNodes() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let annotatedNode = try vrmLoader.node(withNodeIndex: 0)

        #expect(annotatedNode.isHidden == false)
        scene.vrmNode.setFirstPersonRenderMode(.firstPerson)
        #expect(annotatedNode.isHidden == true)
        scene.vrmNode.setFirstPersonRenderMode(.thirdPerson)
        #expect(annotatedNode.isHidden == false)
    }

    @Test
    func testVRM1MToonMaterialIsLoadedFromExtension() throws {
        let vrmLoader = try vrmLoader()
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let gltfMaterial = try #require(vrmLoader.vrm.gltf.jsonData.materials?[0])

        #expect(material.name == gltfMaterial.name)
        #expect(material.lightingModel == .constant)
        #expect(material.isLitPerPixel == false)
        #expect(material.writesToDepthBuffer == true)
    }

    @Test
    func testVRM1NodeConstraintRotationIsApplied() throws {
        let vrmLoader = try vrmLoader()
        let scene = try vrmLoader.loadScene()
        let target = try vrmLoader.node(withNodeIndex: 14)
        let source = try vrmLoader.node(withNodeIndex: 82)

        let targetRest = target.simdOrientation
        let sourceRest = source.simdOrientation
        let sourceDelta = simd_quatf(angle: 0.35, axis: simd_normalize(SIMD3<Float>(0.2, 0.9, 0.3)))
        source.simdOrientation = sourceRest * sourceDelta

        scene.vrmNode.update(at: 0)

        let expected = targetRest * (simd_inverse(sourceRest) * source.simdOrientation)
        #expect(target.simdOrientation.isApproximatelyEqual(to: expected))
    }
}

private extension simd_quatf {
    func isApproximatelyEqual(to other: simd_quatf, tolerance: Float = 0.0001) -> Bool {
        abs(simd_dot(vector, other.vector)) > 1.0 - tolerance
    }
}
