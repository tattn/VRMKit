import Foundation
import Testing
import VRMTestSupport
@testable import VRMKit

/// Parses the Khronos CC0 sample assets, covering what the VRM fixtures, all
/// GLB with an embedded BIN chunk, never reach: JSON `.gltf` files with
/// external resources and with data URI buffers.
@Suite
struct GLTFSampleAssetTests {
    @Test(arguments: GLTFSampleAsset.allCases)
    func testEverySampleAssetLoadsAndResolvesItsBuffers(_ asset: GLTFSampleAsset) throws {
        let document = try GLTFLoader().load(withURL: asset.url)

        #expect(document.gltf.asset.version.hasPrefix("2."))
        #expect(document.gltf.nodes?.isEmpty == false)
        #expect(document.gltf.meshes?.isEmpty == false)

        // Reading every buffer view proves the resource context is right: GLB
        // chunk, sibling file or data URI, whichever this asset uses.
        for index in (document.gltf.bufferViews ?? []).indices {
            #expect(try !document.bufferViewData(at: index).data.isEmpty)
        }
    }

    @Test
    func testExternalBinaryResolvesRelativeToTheGLTFFile() throws {
        let document = try GLTFLoader().load(withURL: GLTFSampleAsset.triangle.url)

        #expect(document.binaryBuffer == nil)
        #expect(document.rootDirectory != nil)
        // Triangle.bin holds 3 vertices of 3 floats plus 3 shorts of indices.
        #expect(try document.bufferData(at: 0).count == 44)
    }

    @Test
    func testExternalBinaryFailsWithoutARootDirectory() throws {
        // Loaded from memory there is nowhere to resolve "Triangle.bin" from.
        let document = try GLTFLoader().load(withData: GLTFSampleAsset.triangle.data)

        #expect(throws: (any Error).self) {
            _ = try document.bufferData(at: 0)
        }
    }

    @Test
    func testEmbeddedDataURIBufferNeedsNoRootDirectory() throws {
        let document = try GLTFLoader().load(withData: GLTFSampleAsset.simpleSkin.data)

        #expect(document.binaryBuffer == nil)
        #expect(try !document.bufferData(at: 0).isEmpty)
        #expect(document.gltf.skins?.count == 1)
    }

    @Test
    func testGLBSampleAssetLoadsThroughTheBinaryPath() throws {
        let document = try GLTFLoader().load(withData: GLTFSampleAsset.boxVertexColors.data)

        #expect(document.binaryBuffer != nil)
        let primitive = try #require(document.gltf.meshes?.first?.primitives.first)
        #expect(primitive.attributes.rawValue[.COLOR_0] != nil)
    }

    @Test
    func testAnimationModelDecodesChannelsAndSamplers() throws {
        let document = try GLTFLoader().load(withData: GLTFSampleAsset.simpleMorph.data)
        let animation = try #require(document.gltf.animations?.first)
        let channel = try #require(animation.channels.first)

        #expect(channel.target.node == 0)
        #expect(channel.target.targetPath == .weights)
        #expect(animation.samplers[channel.sampler].interpolation == .LINEAR)
    }

    @Test
    func testInterpolationTestCoversEveryInterpolationMode() throws {
        let document = try GLTFLoader().load(withData: GLTFSampleAsset.interpolationTest.data)
        let animations = try #require(document.gltf.animations)
        let interpolations = Set(animations.flatMap { $0.samplers.map(\.interpolation) })

        #expect(interpolations == [.LINEAR, .STEP, .CUBICSPLINE])
        // Every channel targets a node by index, what the runtime binds against.
        for animation in animations {
            for channel in animation.channels {
                #expect(channel.target.node != nil)
                #expect(channel.target.targetPath != nil)
            }
        }
    }
}
