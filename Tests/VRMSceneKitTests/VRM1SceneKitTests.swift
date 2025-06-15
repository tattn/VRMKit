import VRMKit
@testable import VRMSceneKit
import SceneKit
import Testing

@Suite
struct VRM1SceneLoaderTests {

    func vrm1Loader() throws -> VRM1SceneLoader {
        let url = Bundle.module.url(forResource: "Seed-san", withExtension: "vrm")!
        return try VRM1SceneLoader(withURL: url)
    }

    @Test
    func testLoadVRM1() throws {
        let vrm1Loader = try vrm1Loader()
        let vrm1 = vrm1Loader.vrm1
        let gltf = vrm1.gltf.jsonData

        #expect(vrm1.meta.name == "Seed-san")
        #expect(gltf.asset.version == "2.0")
        #expect(gltf.buffers!.map(\.byteLength) == [10783033])
        #expect(gltf.bufferViews!.count == 404)
        #expect(gltf.scene == 0)
        #expect(gltf.scenes!.map(\.nodes).map(\.?.count) == [7])

        let thumbnail = try vrm1Loader.loadThumbnail()!
        #expect(thumbnail.size == CGSize(width: 512, height: 512))
    }

    @Test
    func testBufferAccess() throws {
        let vrm1Loader = try vrm1Loader()
        let result = try vrm1Loader.bufferView(withBufferViewIndex: 0)
        #expect(result.stride == nil)
        #expect(result.bufferView.count == 93840)
    }
}
