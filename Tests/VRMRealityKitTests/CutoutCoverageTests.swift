#if canImport(RealityKit)
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
        let entity = try await prepared.loadEntity()
        #expect(prepared.resources.cutoutsDrawnOpaque[0] == true)
        #expect(try #require(try prepared.material(withMaterialIndex: 0) as? UnlitMaterial).opacityThreshold == nil)
        // The asset the entity's instance moves says so too, for an app drawing it itself.
        let data = try #require(entity.instance?.asset.materials[0])
        #expect(data.alphaMode == .MASK)
        #expect(data.resolvedAlphaMode == .OPAQUE)
    }

    @Test
    func testMaskMaterialCuttingSomethingOutKeepsTheCutout() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: try seedSanWithHair(alphaMode: "MASK", baseColorAlpha: 0.2),
                                         shaders: [])
        let material = try #require(try loader.material(withMaterialIndex: 0) as? UnlitMaterial)
        #expect(material.opacityThreshold == 0.5)
        #expect(!loader.inspector.drawsCutoutOpaque(materialIndex: 0))
        let entity = try await loader.loadEntity()
        #expect(entity.instance?.asset.materials[0].resolvedAlphaMode == .MASK)
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
