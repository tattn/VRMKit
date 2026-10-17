#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// A MASK material discarding nothing draws opaque, so the GPU keeps rejecting what it
/// hides; one that cuts anything out keeps the cutout draw.
@Suite
@MainActor
struct CutoutCoverageTests {
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
    private let topLeft: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]

    @Test
    func testTrianglesOverOpaqueTexelsSampleOnlyOpaqueTexels() {
        let plane = plane(transparent: [(x: 3, y: 3)])
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == true)
    }

    @Test
    func testTriangleOverTransparentTexelCutsOut() {
        let plane = plane(transparent: [(x: 0, y: 0)])
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == false)
    }

    @Test
    func testWindingDoesNotMatter() {
        let plane = plane(transparent: [(x: 0, y: 0)])
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: topLeft,
                                                 indices: [0, 2, 1],
                                                 sampling: .init(),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == false)
    }

    @Test
    func testRepeatingUVsWrapIntoThePlane() {
        let plane = plane(transparent: [(x: 0, y: 0)])
        let shifted: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(2, 1), SIMD2(1, 2)]
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: shifted,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(wrapS: .REPEAT, wrapT: .REPEAT),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == false)
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: shifted,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(wrapS: .CLAMP_TO_EDGE, wrapT: .CLAMP_TO_EDGE),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == true)
    }

    @Test
    func testTextureTransformMovesTheSampledTexels() {
        let plane = plane(transparent: [(x: 3, y: 3)])
        let transform = GLTFUVTransform(scale: SIMD2(1, 1), offset: SIMD2(0.5, 0.5))
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(transform: transform),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == false)
    }

    @Test
    func testBaseColorAlphaFactorCountsTowardTheCutoff() {
        var alpha = [UInt8](repeating: 255, count: 16)
        alpha[0] = 160
        let plane = Coverage.AlphaPlane(width: 4, height: 4, alpha: alpha)
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == true)
        // 160 / 255 × 0.7 < 0.5
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 0.7,
                                                 cutoff: 0.5) == false)
        // A factor under the cutoff cuts the whole material out: nothing to decide.
        #expect(Coverage.samplesOnlyOpaqueTexels(of: plane,
                                                 texcoords: topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 0.4,
                                                 cutoff: 0.5) == nil)
    }

    @Test
    func testImageWithoutAlphaIsOpaqueEverywhere() {
        #expect(Coverage.samplesOnlyOpaqueTexels(of: nil,
                                                 texcoords: topLeft,
                                                 indices: [0, 1, 2],
                                                 sampling: .init(),
                                                 alphaFactor: 1,
                                                 cutoff: 0.5) == true)
        #expect(Coverage.isOpaqueEverywhere(nil, alphaFactor: 1, cutoff: 0.5) == true)
        #expect(Coverage.isOpaqueEverywhere(plane(transparent: [(x: 3, y: 3)]), alphaFactor: 1, cutoff: 0.5) == false)
    }

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

    /// Seed-san's hair texture carries no alpha, so marked MASK it would discard nothing.
    private func seedSanWithHair(alphaMode: String, baseColorAlpha: Float = 1) throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "hair \(alphaMode) \(baseColorAlpha)") { json in
            var materials = json.objects("materials")
            materials[0]["alphaMode"] = .string(alphaMode)
            var pbr = materials[0].object("pbrMetallicRoughness") ?? [:]
            pbr["baseColorFactor"] = .simd(SIMD4<Float>(1, 1, 1, baseColorAlpha))
            materials[0]["pbrMetallicRoughness"] = .object(pbr)
            json["materials"] = .objects(materials)
        }
    }

    @Test
    func testMaskMaterialDiscardingNothingDrawsOpaque() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: try seedSanWithHair(alphaMode: "MASK"), shaders: [])
        let material = try #require(try loader.material(withMaterialIndex: 0) as? UnlitMaterial)
        #expect(material.opacityThreshold == nil)
        #expect(loader.inspector.drawsCutoutOpaque(materialIndex: 0))

        // The prepared load decides the same, off the actor.
        let prepared = try VRMEntityLoader(withData: try seedSanWithHair(alphaMode: "MASK"), shaders: [])
        _ = try await prepared.loadEntity()
        #expect(prepared.resources.cutoutsDrawnOpaque[0] == true)
        #expect(try #require(try prepared.material(withMaterialIndex: 0) as? UnlitMaterial).opacityThreshold == nil)
    }

    @Test
    func testMaskMaterialCuttingSomethingOutKeepsTheCutout() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: try seedSanWithHair(alphaMode: "MASK", baseColorAlpha: 0.2),
                                         shaders: [])
        let material = try #require(try loader.material(withMaterialIndex: 0) as? UnlitMaterial)
        #expect(material.opacityThreshold == 0.5)
        #expect(!loader.inspector.drawsCutoutOpaque(materialIndex: 0))
    }

    @Test
    func testOpaqueAndBlendMaterialsAreLeftAlone() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: try seedSanWithHair(alphaMode: "BLEND"), shaders: [])
        #expect(!loader.inspector.drawsCutoutOpaque(materialIndex: 0))
        #expect(try loader.inspector.makeMaterialShaderContext(withMaterialIndex: 0).resolvedAlphaMode == .BLEND)
        let opaque = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: [])
        #expect(!opaque.inspector.drawsCutoutOpaque(materialIndex: 0))
    }

#if !os(visionOS)
    @Test
    func testMToonMaskMaterialDiscardingNothingDrawsWithTheOpaqueSurface() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: try seedSanWithHair(alphaMode: "MASK"))
        let material = try #require(try loader.material(withMaterialIndex: 0) as? CustomMaterial,
                                    TestSupport.expectedCustomMaterialMessage)
        // CustomMaterial reads an unset threshold back as 0.
        #expect((material.opacityThreshold ?? 0) == 0)
        let context = try loader.inspector.makeMaterialShaderContext(withMaterialIndex: 0)
        #expect(try context.mtoonResolution().descriptor?.alphaMode == .OPAQUE)

        let cutout = try VRMEntityLoader(withData: try seedSanWithHair(alphaMode: "MASK", baseColorAlpha: 0.2))
        let cutoutMaterial = try #require(try cutout.material(withMaterialIndex: 0) as? CustomMaterial,
                                          TestSupport.expectedCustomMaterialMessage)
        #expect(cutoutMaterial.opacityThreshold == 0.5)
    }
#endif
}
#endif
