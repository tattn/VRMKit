import Foundation
import Testing
import VRMTestSupport
@testable import VRMKit

@Suite
struct GLTFLoaderTests {
    @Test
    func testGLBDataLoadsAsBinaryDocument() throws {
        let document = try GLTFLoader().load(withData: VRMSampleAsset.aliciaSolid.data)

        #expect(document.binaryBuffer != nil)
        #expect(document.gltf.nodes?.isEmpty == false)
        // The BIN chunk resolves through the document without a root directory.
        #expect(try document.bufferData(at: 0).isEmpty == false)
    }

    @Test
    func testJSONDataLoadsAsDocumentWithDataURIBuffer() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "scenes": [{"nodes": [0]}],
            "nodes": [{"name": "root"}],
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAw==", "byteLength": 4}]
        }
        """
        let document = try GLTFLoader().load(withData: Data(json.utf8))

        #expect(document.binaryBuffer == nil)
        #expect(document.gltf.nodes?.count == 1)
        #expect(try document.bufferData(at: 0) == Data([0, 1, 2, 3]))
    }

    /// RFC 2397 makes `;base64` optional: without it the data is percent-encoded
    /// octets, which glTF allows for an image `uri`.
    @Test
    func testPercentEncodedDataURIResolvesToItsOctets() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "data:application/octet-stream,%00%01%02%03", "byteLength": 4}]
        }
        """
        let document = try GLTFLoader().load(withData: Data(json.utf8))

        #expect(try document.bufferData(at: 0) == Data([0, 1, 2, 3]))
    }

    /// A media type of its own is optional too, so the shortest data uri is just
    /// `data:,`.
    @Test
    func testDataURIWithoutAMediaTypeResolves() throws {
        #expect(try Data(gltfUrlString: "data:,AB", relativeTo: nil) == Data("AB".utf8))
        #expect(try Data(gltfUrlString: "data:;base64,QUI=", relativeTo: nil) == Data("AB".utf8))
    }

    @Test
    func testMalformedDataURIFails() {
        // No "," at all, and a truncated percent escape.
        #expect(throws: VRMError.self) { try Data(gltfUrlString: "data:application/octet-stream", relativeTo: nil) }
        #expect(throws: VRMError.self) { try Data(gltfUrlString: "data:,%0", relativeTo: nil) }
        #expect(throws: VRMError.self) { try Data(gltfUrlString: "data:;base64,!!!", relativeTo: nil) }
    }

    @Test
    func testJSONDataWithUnsupportedAssetVersionFails() {
        let json = """
        {"asset": {"version": "1.0"}}
        """
        #expect(throws: VRMError.self) {
            try GLTFLoader().load(withData: Data(json.utf8))
        }
    }

    /// A glTF `uri` is a URI reference, so a resource whose name needs escaping
    /// is referenced percent-encoded and has to be resolved that way.
    @Test
    func testPercentEncodedExternalResourceResolves() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VRMKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data([0, 1, 2, 3])
        try payload.write(to: directory.appendingPathComponent("My Buffer.bin"))
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "My%20Buffer.bin", "byteLength": 4}]
        }
        """
        let document = try GLTFLoader().load(withData: Data(json.utf8), rootDirectory: directory)

        #expect(try document.bufferData(at: 0) == payload)
    }

    /// Resolving a `uri` must not put the loader on the network behind the
    /// caller's back.
    @Test
    func testRemoteResourceURIIsRejected() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "https://example.com/buffer.bin", "byteLength": 4}]
        }
        """
        let document = try GLTFLoader().load(withData: Data(json.utf8))

        #expect(throws: VRMError.self) { try document.bufferData(at: 0) }
    }

    /// A relative `uri` is relative to the directory of the glTF, so a document
    /// loaded from data alone cannot resolve one.
    @Test
    func testRelativeResourceURIWithoutARootDirectoryIsRejected() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "buffer.bin", "byteLength": 4}]
        }
        """
        let document = try GLTFLoader().load(withData: Data(json.utf8))

        #expect(throws: VRMError.self) { try document.bufferData(at: 0) }
        // The same document resolves it once it knows where the asset lives.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VRMKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data([0, 1, 2, 3])
        try payload.write(to: directory.appendingPathComponent("buffer.bin"))

        let located = try GLTFLoader().load(withData: Data(json.utf8), rootDirectory: directory)
        #expect(try located.bufferData(at: 0) == payload)
    }

    /// glTF defaults a node's `rotation` to identity, not to the zero vector.
    @Test
    func testNodeRotationDefaultsToIdentity() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "nodes": [{}, {"rotation": [0, 0.7071068, 0, 0.7071068]}]
        }
        """
        let nodes = try #require(GLTFLoader().load(withData: Data(json.utf8)).gltf.nodes)

        #expect(nodes[0].rotation.w == 1)
        #expect(nodes[0].rotation.x == 0)
        #expect(nodes[1].rotation.y == 0.7071068)
    }

    /// glTF leaves `scene` out for assets that are a library of nodes rather than
    /// something to render, which is not the same as naming scene 0.
    @Test
    func testDefaultSceneIsAbsentWhenTheAssetNamesNone() throws {
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": []}]}
        """
        #expect(try GLTFLoader().load(withData: Data(json.utf8)).gltf.scene == nil)
        #expect(try GLTFLoader().load(withData: VRMSampleAsset.seedSan.data).gltf.scene == 0)
    }

    /// glTF defaults `mode` to TRIANGLES only when the primitive leaves it out;
    /// a value outside 0...6 is malformed and must not silently render as one.
    @Test
    func testPrimitiveModeOutsideTheSpecFailsTheLoad() throws {
        func json(mode: String) -> Data {
            Data("""
            {
                "asset": {"version": "2.0"},
                "meshes": [{"primitives": [{"attributes": {"POSITION": 0}\(mode)}]}]
            }
            """.utf8)
        }
        let defaulted = try GLTFLoader().load(withData: json(mode: "")).gltf
        #expect(defaulted.meshes?.first?.primitives.first?.mode == .TRIANGLES)
        #expect(try GLTFLoader().load(withData: json(mode: #", "mode": 0"#))
            .gltf.meshes?.first?.primitives.first?.mode == .POINTS)
        #expect(throws: (any Error).self) { try GLTFLoader().load(withData: json(mode: #", "mode": 7"#)) }
        #expect(throws: (any Error).self) { try GLTFLoader().load(withData: json(mode: #", "mode": "4""#)) }
    }

    @Test
    func testGLBMagicDetection() {
        #expect(BinaryGLTF.isGLB(VRMSampleAsset.aliciaSolid.data))
        #expect(!BinaryGLTF.isGLB(Data("{\"asset\":{}}".utf8)))
        #expect(!BinaryGLTF.isGLB(Data([0x67, 0x6C])))
    }
}
