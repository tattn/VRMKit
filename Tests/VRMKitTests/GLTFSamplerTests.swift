import Foundation
import Testing
import VRMKit

@Suite
struct GLTFSamplerTests {
    /// Files in the wild put a mipmap constant in magFilter and UniVRM loads them, so the
    /// texel filter it names is read.
    @Test
    func testMipmapMagFilterIsReadAsItsTexelFilter() throws {
        let sampler = try decode(#"{"magFilter": 9987, "minFilter": 9987}"#)

        #expect(sampler.magFilter == .LINEAR)
        #expect(sampler.minFilter == .LINEAR_MIPMAP_LINEAR)
    }

    /// A value that names no filter or wrap is read as absent, so the sampler keeps its defaults.
    @Test
    func testUnknownValuesAreReadAsAbsent() throws {
        let sampler = try decode(#"{"magFilter": 1, "minFilter": 1, "wrapS": 1, "wrapT": 33648}"#)

        #expect(sampler.magFilter == nil)
        #expect(sampler.minFilter == nil)
        #expect(sampler.wrapS == .REPEAT)
        #expect(sampler.wrapT == .MIRRORED_REPEAT)
    }

    @Test
    func testStatedValuesAreRead() throws {
        let sampler = try decode(#"{"magFilter": 9728, "minFilter": 9985, "wrapS": 33071, "name": "s"}"#)

        #expect(sampler.magFilter == .NEAREST)
        #expect(sampler.minFilter == .LINEAR_MIPMAP_NEAREST)
        #expect(sampler.wrapS == .CLAMP_TO_EDGE)
        #expect(sampler.wrapT == .REPEAT)
        #expect(sampler.name == "s")
    }

    private func decode(_ json: String) throws -> GLTF.Sampler {
        try JSONDecoder().decode(GLTF.Sampler.self, from: Data(json.utf8))
    }
}
