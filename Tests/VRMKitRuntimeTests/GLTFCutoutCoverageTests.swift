#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
import VRMKit
@testable import VRMKitRuntime

/// Whether a MASK material's triangles sample only texels its cutoff keeps.
@Suite
struct GLTFCutoutCoverageTests {
    private typealias Coverage = GLTFCutoutCoverage

    /// A 4×4 alpha plane, opaque but for the texels named.
    private func plane(transparent: [(x: Int, y: Int)]) -> Coverage.AlphaPlane {
        var alpha = [UInt8](repeating: 255, count: 16)
        for texel in transparent {
            alpha[texel.y * 4 + texel.x] = 0
        }
        return Coverage.AlphaPlane(width: 4, height: 4, alpha: alpha)
    }

    /// One triangle covering the top-left half of the plane.
    private static let topLeft: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]

    /// Triangles drawn over a plane opaque but for one texel, and whether they
    /// sample only opaque texels.
    struct Sample: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let transparent: (x: Int, y: Int)
        var texcoords: [SIMD2<Float>] = GLTFCutoutCoverageTests.topLeft
        var indices: [UInt32] = [0, 1, 2]
        var sampling = GLTFCutoutCoverage.Sampling()
        let samplesOnlyOpaqueTexels: Bool
    }

    @Test(arguments: [
        Sample(testDescription: "triangles over opaque texels", transparent: (3, 3),
               samplesOnlyOpaqueTexels: true),
        Sample(testDescription: "a triangle over a transparent texel", transparent: (0, 0),
               samplesOnlyOpaqueTexels: false),
        Sample(testDescription: "the other winding", transparent: (0, 0), indices: [0, 2, 1],
               samplesOnlyOpaqueTexels: false),
        Sample(testDescription: "repeating UVs wrapping into the plane", transparent: (0, 0),
               texcoords: [SIMD2(1, 1), SIMD2(2, 1), SIMD2(1, 2)],
               sampling: .init(wrapS: .REPEAT, wrapT: .REPEAT), samplesOnlyOpaqueTexels: false),
        Sample(testDescription: "clamped UVs past the plane", transparent: (0, 0),
               texcoords: [SIMD2(1, 1), SIMD2(2, 1), SIMD2(1, 2)],
               sampling: .init(wrapS: .CLAMP_TO_EDGE, wrapT: .CLAMP_TO_EDGE), samplesOnlyOpaqueTexels: true),
        Sample(testDescription: "a texture transform moving the sampled texels", transparent: (3, 3),
               sampling: .init(transform: GLTFUVTransform(scale: SIMD2(1, 1), offset: SIMD2(0.5, 0.5))),
               samplesOnlyOpaqueTexels: false)
    ])
    func testTheTexelsATriangleSamplesDecideWhetherItCutsOut(_ sample: Sample) {
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane(transparent: [sample.transparent]),
                                                 texcoords: sample.texcoords,
                                                 indices: sample.indices,
                                                 sampling: sample.sampling,
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == sample.samplesOnlyOpaqueTexels)
    }

    @Test
    func testBaseColorAlphaFactorCountsTowardTheCutoff() {
        var alpha = [UInt8](repeating: 255, count: 16)
        alpha[0] = 160
        let plane = Coverage.AlphaPlane(width: 4, height: 4, alpha: alpha)
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: Self.topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == true)
        // 160 / 255 × 0.7 < 0.5
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: Self.topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 0.7,
                                                 cutoff: 0.5) == false)
        // A factor under the cutoff cuts the whole material out: nothing to decide.
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: Self.topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 0.4,
                                                 cutoff: 0.5) == nil)
    }

    @Test
    func testImageWithoutAlphaIsOpaqueEverywhere() {
        #expect(Coverage.samplesOnlyOpaqueTexels(of: nil,
                                                 texcoords: Self.topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == true)
        #expect(Coverage.isOpaqueEverywhere(nil, alphaFactor: 1, cutoff: 0.5) == true)
        #expect(Coverage.isOpaqueEverywhere(plane(transparent: [(x: 3, y: 3)]), alphaFactor: 1, cutoff: 0.5) == false)
    }

#if canImport(CoreGraphics)
    @Test
    func testAlphaPlaneReadsTheImageAlphaRowsFromTheTop() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        // Core Graphics draws from the bottom, so this clears the top-left texel.
        context.clear(CGRect(x: 0, y: 1, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let plane = try #require(Coverage.AlphaPlane(image))
        #expect(plane.alpha == [0, 255, 255, 255])

        let opaque = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        #expect(Coverage.AlphaPlane(try #require(opaque.makeImage())) == nil)
    }
#endif
}
