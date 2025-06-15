import VRMKit
@testable import VRMSceneKit
import SceneKit
import Testing

@Suite
struct VRM1SceneLoaderTests {

    func vrm1Loader() throws -> VRM1SceneLoader {
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"), "Failed to load Seed-san.vrm resource from test bundle.")
        return try VRM1SceneLoader(withURL: url)
    }

    @Test
    func testLoadVRM1() throws {
        let vrm1Loader = try vrm1Loader()
        let vrm1 = vrm1Loader.vrm1
        let gltf = vrm1.gltf.jsonData

        #expect(vrm1.meta.name == "Seed-san")
        #expect(gltf.asset.version == "2.0")
        #expect(try #require(gltf.buffers, "GLTF buffers should not be nil").map(\.byteLength) == [10783033])
        #expect(try #require(gltf.bufferViews, "GLTF bufferViews should not be nil").count == 404)
        #expect(gltf.scene == 0)
        #expect(try #require(gltf.scenes, "GLTF scenes should not be nil").map(\.nodes).map(\.?.count) == [7])

        let thumbnail = try #require(try vrm1Loader.loadThumbnail(), "Thumbnail should be loadable and not nil.")
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
