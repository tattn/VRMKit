import Foundation
import Testing
import VRMTestSupport
@testable import VRMKit

@Suite
struct VRMThumbnailTests {
    /// VRM 0.x names its thumbnail through a texture and VRM 1.0 through an image, and
    /// both resolve through the one image reader the document carries.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testThumbnailDecodes(asset: VRMSampleAsset) throws {
        let vrm = try VRM(data: asset.data)

        let thumbnail = try vrm.thumbnail

        #expect(thumbnail.width > 0)
        #expect(thumbnail.height > 0)
    }

    /// An image kept beside the model resolves against the directory it was loaded from,
    /// as every other external resource does.
    @Test
    func testThumbnailKeptInAFileResolvesAgainstTheModelsDirectory() throws {
        let asset = VRMSampleAsset.seedSan
        let source = try VRM(data: asset.data)
        let imageIndex = try source.thumbnailImageIndex.rawValue
        let bufferView = try #require(source.document.gltf.images[imageIndex].bufferView)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VRMThumbnailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try source.document.bufferViewData(at: bufferView).data
            .write(to: directory.appendingPathComponent("thumbnail.png"))

        let external = try asset.rewritingJSON { json in
            var images = json.objects("images")
            images[imageIndex].removeValue(forKey: "bufferView")
            images[imageIndex]["uri"] = "thumbnail.png"
            json["images"] = .objects(images)
        }
        let vrm = try VRM(data: external, rootDirectory: directory)

        #expect(try (vrm.thumbnail.width, vrm.thumbnail.height) == (source.thumbnail.width, source.thumbnail.height))
    }
}
