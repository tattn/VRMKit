#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// The shader-chain seam of the loaders: custom `GLTFMaterialShader`s take over
/// material building, and `MToonShader(source: .convertAll)` toon-shades plain
/// glTF assets that carry no MToon data.
@Suite
@MainActor
struct MaterialShaderChainTests {

    /// A chain-less loader renders everything through the built-in Unlit / PBR
    /// path.
    @Test
    func testEmptyShaderChainRendersStandardMaterials() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url, shaders: [])
        #expect(try loader.material(withMaterialIndex: 0) is PhysicallyBasedMaterial)
    }

    /// The first shader returning a material wins; later shaders and the
    /// built-in path never see the material.
    @Test
    func testCustomShaderTakesOverMaterialBuilding() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        final class SolidColorShader: GLTFMaterialShader {
            private(set) var seenMaterialIndices: [Int] = []

            func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
                seenMaterialIndices.append(context.materialIndex)
                var material = UnlitMaterial(applyPostProcessToneMap: false)
                material.color = .init(tint: .magenta)
                return GLTFShadedMaterial(material: material)
            }
        }

        let shader = SolidColorShader()
        let loader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url, shaders: [shader])
        let entity = try loader.loadEntity()

        #expect(shader.seenMaterialIndices == [0])
        for modelEntity in entity.modelEntitiesInHierarchy {
            let materials = modelEntity.components[ModelComponent.self]?.materials ?? []
            #expect(materials.allSatisfy { $0 is UnlitMaterial })
        }
    }

    /// A shader that passes (returns nil) falls through to the built-in path.
    @Test
    func testDecliningShaderFallsThroughToTheStandardPath() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        final class DecliningShader: GLTFMaterialShader {
            func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
                nil
            }
        }

        let loader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                          shaders: [DecliningShader()])
        #expect(try loader.material(withMaterialIndex: 0) is PhysicallyBasedMaterial)
    }

    /// A custom shader's extra passes become sibling model entities, the way
    /// MToon outlines do.
    @Test
    func testAdditionalPassesBecomeSiblingModelEntities() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        final class TwoPassShader: GLTFMaterialShader {
            func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
                GLTFShadedMaterial(material: UnlitMaterial(),
                                   additionalPasses: [.init(material: UnlitMaterial(), name: "halo")])
            }
        }

        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                          shaders: [TwoPassShader()]).loadEntity()
        let modelEntities = entity.modelEntitiesInHierarchy
        #expect(modelEntities.count == 2)
        #expect(modelEntities.contains { $0.name.hasSuffix("_halo") })
        // Both passes share the material index, so runtime updates reach them together.
        #expect(modelEntities.allSatisfy {
            $0.components[GLTFMaterialIndexComponent.self]?.materialIndex == 0
        })
    }

    /// A custom shader whose material makes an animatable state gets that
    /// per-entity state driven end to end by VRM expression material binds, the
    /// way MToon does: baseline reads at load, `setColor` accumulation, one
    /// `prepareFlush()` per change, and `apply(to:)` for every material
    /// instance rendering the bound glTF material.
    @Test
    func testCustomAnimatingShaderIsDrivenByExpressionBinds() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let target = SIMD4<Float>(0, 1, 0, 1)
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "custom-shader-color-bind") { preset in
            guard var happy = preset["happy"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san happy expression")
            }
            happy["materialColorBinds"] = [[
                "material": 0,
                "type": "color",
                "targetValue": [0.0, 1.0, 0.0, 1.0]
            ]]
            preset["happy"] = happy
        }

        final class TintState: VRMAnimatableMaterialState {
            var currentColor = SIMD4<Float>(1, 1, 1, 1)
            private(set) var flushCount = 0
            private(set) var applyCount = 0

            func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float>? {
                type == .color ? currentColor : nil
            }

            func setColor(_ color: SIMD4<Float>,
                          for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Bool {
                guard type == .color else { return false }
                currentColor = color
                return true
            }

            // Animates the base color only; the rest is left to the material.
            func prepareFlush() -> Bool {
                flushCount += 1
                return true
            }

            func apply(to material: any Material) -> any Material {
                applyCount += 1
                return material
            }
        }

        final class TintShader: GLTFMaterialShader {
            private(set) var createdStates: [(materialIndex: Int, state: TintState)] = []

            func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
                let materialIndex = context.materialIndex
                return GLTFShadedMaterial(material: UnlitMaterial()) { [weak self] in
                    let state = TintState()
                    self?.createdStates.append((materialIndex, state))
                    return state
                }
            }
        }

        let shader = TintShader()
        let vrmEntity = try VRMEntityLoader(withData: modified, shaders: [shader]).loadEntity()
        // Material bindings register while meshes build, before the expression
        // setup reads its baselines, so the first state per index is the one
        // the entity holds.
        let state = try #require(shader.createdStates.first { $0.materialIndex == 0 }?.state)
        #expect(state.flushCount == 0)

        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        #expect(state.currentColor.isApproximatelyEqual(to: target))
        #expect(state.flushCount == 1)
        #expect(state.applyCount >= 1)

        // Releasing the expression writes the baseline back through the state.
        vrmEntity.setExpression(value: 0, for: .preset(.happy))
        #expect(state.currentColor.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))
        #expect(state.flushCount == 2)
    }

    /// A state claims values one at a time, so a color-only state does not
    /// swallow the binds it does not animate: Seed-san's `happy`
    /// textureTransformBind still reaches material 11.
    @Test
    func testUnclaimedBindsFallBackToTheRealityKitMaterial() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        final class ColorOnlyState: VRMAnimatableMaterialState {
            var currentColor = SIMD4<Float>(1, 1, 1, 1)

            func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float>? {
                type == .color ? currentColor : nil
            }

            func setColor(_ color: SIMD4<Float>,
                          for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Bool {
                guard type == .color else { return false }
                currentColor = color
                return true
            }

            func apply(to material: any Material) -> any Material { material }
        }

        final class ColorOnlyShader: GLTFMaterialShader {
            func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
                GLTFShadedMaterial(material: UnlitMaterial()) { ColorOnlyState() }
            }
        }

        let vrmEntity = try VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: [ColorOnlyShader()]).loadEntity()
        vrmEntity.setExpression(value: 1, for: .preset(.happy))

        let transforms = vrmEntity.modelEntitiesInHierarchy
            .filter { $0.components[GLTFMaterialIndexComponent.self]?.materialIndex == 11 }
            .flatMap { $0.components[ModelComponent.self]?.materials ?? [] }
            .compactMap { ($0 as? UnlitMaterial)?.textureCoordinateTransform }
        #expect(!transforms.isEmpty)
        #expect(transforms.allSatisfy { $0.offset.isApproximatelyEqual(to: SIMD2<Float>(0.25, 0)) })
    }

    /// A VRM material the chain fails to build renders with the default
    /// material, and that fallback is what the rest of the load sees: the chain
    /// is not asked a second time, so the runtime state can never come from a
    /// material that is not on screen.
    @Test
    func testFailedVRMMaterialFallsBackOnceAndCarriesNoAnimatableState() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        /// Animates nothing, so every bindable value keeps falling back to the
        /// RealityKit material.
        final class StubState: VRMAnimatableMaterialState {
            func apply(to material: any Material) -> any Material { material }
        }

        /// Fails material 0 the first time it is asked and succeeds afterwards,
        /// the way a shader depending on transient state would.
        final class FailOnceShader: GLTFMaterialShader {
            private(set) var callCounts: [Int: Int] = [:]

            func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
                let index = context.materialIndex
                callCounts[index, default: 0] += 1
                if index == 0, callCounts[index] == 1 {
                    throw VRMError.notSupported("simulated material failure")
                }
                return GLTFShadedMaterial(material: UnlitMaterial()) { StubState() }
            }
        }

        let shader = FailOnceShader()
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: [shader])
        let entity = try loader.loadEntity()

        #expect(shader.callCounts[0] == 1)
        // The default material, not the UnlitMaterial the retry would build.
        #expect(try loader.material(withMaterialIndex: 0) is PhysicallyBasedMaterial)
        #expect(loader.makeAnimatableMaterialState(forMaterialIndex: 0) == nil)
        #expect(shader.callCounts[0] == 1)
        // Only the failed material falls back; the rest render through the shader.
        #expect(try loader.material(withMaterialIndex: 1) is UnlitMaterial)
        #expect(loader.makeAnimatableMaterialState(forMaterialIndex: 1) != nil)
        #expect(entity.mtoonParameters(forMaterialIndex: 0) == nil)
    }

#if !os(visionOS)
    /// A document that merely *uses* `VRMC_materials_mtoon` renders a material
    /// MToon cannot build through the rest of the chain, here the built-in
    /// Unlit path, since the material is authored as MToon.
    @Test
    func testUnbuildableMToonMaterialFallsThroughWhenTheExtensionIsOptional() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: Self.brokenMToonSeedSanData(isRequired: false))
        _ = try loader.loadEntity()
        #expect(try loader.material(withMaterialIndex: 0) is UnlitMaterial)
    }

    /// A generic glTF load honors `extensionsRequired`: a document that cannot be
    /// drawn without `VRMC_materials_mtoon` fails the whole load rather than
    /// rendering an Unlit approximation of the material MToon could not build.
    @Test
    func testUnbuildableMToonMaterialFailsTheGLTFLoadWhenTheExtensionIsRequired() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withData: Self.brokenMToonSeedSanData(isRequired: true))
        #expect(throws: (any Error).self) {
            try loader.loadEntity()
        }
    }

    /// A VRM keeps rendering whatever this renderer can build, so the same
    /// document loads: the material MToon could not build falls through to the
    /// Unlit approximation rather than dropping to the default material.
    @Test
    func testUnbuildableRequiredMToonMaterialStillRendersInAVRM() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: Self.brokenMToonSeedSanData(isRequired: true))
        let entity = try loader.loadEntity()
        #expect(try loader.material(withMaterialIndex: 0) is UnlitMaterial)
        // The rest of the model still renders as MToon.
        #expect(TestSupport.hasCustomMaterial(in: entity))
    }

    /// A document requiring `KHR_texture_transform` while giving *MToon's own*
    /// textures different transforms asks for a result no path of this renderer
    /// draws. The loader's check only sees the core glTF material's textures,
    /// so MToon rejects this one itself.
    @Test
    func testRequiredTextureTransformFailsWhenMToonTexturesDisagree() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "mixed-mtoon-texture-transform") { json in
            json["extensionsRequired"] = (json["extensionsRequired"] as? [String] ?? [])
                + ["KHR_texture_transform"]
            guard var materials = json["materials"] as? [[String: Any]],
                  var extensions = materials.first?["extensions"] as? [String: Any],
                  var mtoon = extensions["VRMC_materials_mtoon"] as? [String: Any],
                  var shade = mtoon["shadeMultiplyTexture"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon shade texture")
            }
            // The core material's textures still agree, so only MToon's own
            // texture set makes the transforms disagree.
            shade["extensions"] = ["KHR_texture_transform": ["scale": [2.0, 2.0]]]
            mtoon["shadeMultiplyTexture"] = shade
            extensions["VRMC_materials_mtoon"] = mtoon
            materials[0]["extensions"] = extensions
            json["materials"] = materials
        }

        #expect(throws: (any Error).self) {
            try GLTFEntityLoader(withData: modified).loadEntity()
        }
        // The same document renders as a VRM, through the single-transform
        // approximation MToon logs.
        #expect(try VRMEntityLoader(withData: modified).material(withMaterialIndex: 0) is CustomMaterial)
    }

    /// Seed-san with material 0's MToon shade texture pointing past the end of
    /// the texture array, so building it as MToon fails.
    private static func brokenMToonSeedSanData(isRequired: Bool) throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "broken-mtoon-texture-\(isRequired ? "required" : "used")") { json in
            if isRequired {
                json["extensionsRequired"] = (json["extensionsRequired"] as? [String] ?? [])
                    + ["VRMC_materials_mtoon"]
            }
            guard var materials = json["materials"] as? [[String: Any]],
                  var extensions = materials.first?["extensions"] as? [String: Any],
                  var mtoon = extensions["VRMC_materials_mtoon"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon extension")
            }
            mtoon["shadeMultiplyTexture"] = ["index": 9999]
            extensions["VRMC_materials_mtoon"] = mtoon
            materials[0]["extensions"] = extensions
            json["materials"] = materials
        }
    }

    /// `.convertAll` toon-shades a plain glTF: its PBR material renders through
    /// the MToon `CustomMaterial`, with the shade color derived from the base
    /// color and the shade texture reusing the base color texture.
    @Test
    func testConvertAllRendersAPlainGLTFMaterialAsMToon() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(shadeColorScale: 0.5)
        let loader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                          shaders: [MToonShader(source: .convertAll(style))])
        let material = try #require(try loader.material(withMaterialIndex: 0) as? CustomMaterial,
                                    TestSupport.expectedCustomMaterialMessage)
        #expect(material.custom.texture != nil)

        let state = try #require(loader.makeAnimatableMaterialState(forMaterialIndex: 0)
            as? MToonAnimatableMaterialState)
        let baseColor = state.parameters.baseColor
        let expectedShade = SIMD4<Float>(baseColor.x * 0.5, baseColor.y * 0.5, baseColor.z * 0.5, 1)
        #expect(state.parameters.shadeColor == expectedShade)
        // The shade side samples the base color texture, so it keeps its detail.
        #expect(material.roughness.texture != nil)
    }

    /// `.authoredOnly` (the default) leaves a plain glTF material alone.
    @Test
    func testAuthoredOnlyLeavesAPlainGLTFMaterialStandard() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url)
        #expect(try loader.material(withMaterialIndex: 0) is PhysicallyBasedMaterial)
        #expect(loader.makeAnimatableMaterialState(forMaterialIndex: 0) == nil)
    }

    /// A converted material with an outline style gets the inverted-hull
    /// outline entity, like an authored MToon material would.
    @Test
    func testConvertAllWithOutlineStyleCreatesOutlineEntities() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                          shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        // Named after the mesh it belongs to, not after the unnamed model entity.
        let outline = try #require(entity.modelEntitiesInHierarchy.first { $0.name.hasSuffix("_outline") })
        let mesh = try #require(outline.parent?.parent)
        #expect(!mesh.name.isEmpty)
        #expect(outline.name == "\(mesh.name)_outline")
        #expect(outline.parent?.name == "\(mesh.name)_container")

        let noOutline = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                             shaders: [MToonShader(source: .convertAll)]).loadEntity()
        #expect(!noOutline.modelEntitiesInHierarchy.contains { $0.name.hasSuffix("_outline") })
    }

    /// `.convertAll` keeps the authored values of a material that already
    /// carries MToon data.
    @Test
    func testConvertAllKeepsAuthoredMToonMaterials() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func shadeColor(of loader: GLTFEntityLoader) throws -> SIMD4<Float> {
            _ = try loader.material(withMaterialIndex: 0)
            let state = try #require(loader.makeAnimatableMaterialState(forMaterialIndex: 0)
                as? MToonAnimatableMaterialState)
            return state.parameters.shadeColor
        }

        let authored = try VRMEntityLoader(withData: TestSupport.seedSanData,
                                           shaders: [MToonShader()])
        let converted = try VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: [MToonShader(source: .convertAll)])
        #expect(try shadeColor(of: converted) == shadeColor(of: authored))
    }

    /// An unreadable MToon material is still MToon, so `.convertAll` leaves it to
    /// the Unlit approximation rather than inventing toon values over the ones it
    /// is already authored with.
    @Test
    func testConvertAllLeavesUnreadableMToonVersionsAlone() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let futureVersion = try Self.seedSanDataWithMToonSpecVersion("1.1", isRequired: false)

        for source in [MToonShader.Source.authoredOnly, .convertAll] {
            let loader = try VRMEntityLoader(withData: futureVersion,
                                             shaders: [MToonShader(source: source)])
            let entity = try loader.loadEntity()
            #expect(try loader.material(withMaterialIndex: 0) is UnlitMaterial)
            #expect(entity.mtoonParameters(forMaterialIndex: 0) == nil)
            // Only the unreadable material drops out; the rest still convert.
            #expect(try loader.material(withMaterialIndex: 1) is CustomMaterial,
                    TestSupport.expectedCustomMaterialMessage)
        }
    }

    /// A document that cannot be drawn without `VRMC_materials_mtoon` is not
    /// drawable through the Unlit approximation either, so an unreadable MToon
    /// version fails the generic glTF load.
    @Test
    func testUnreadableMToonVersionFailsTheGLTFLoadWhenTheExtensionIsRequired() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let required = try Self.seedSanDataWithMToonSpecVersion("1.1", isRequired: true)
        #expect(throws: (any Error).self) {
            try GLTFEntityLoader(withData: required).loadEntity()
        }
        // A VRM renders with whatever this renderer can build, so the same
        // document still loads through the Unlit approximation.
        let vrmLoader = try VRMEntityLoader(withData: required)
        _ = try vrmLoader.loadEntity()
        #expect(try vrmLoader.material(withMaterialIndex: 0) is UnlitMaterial)
    }

    /// Seed-san with material 0's MToon `specVersion` replaced, so its authored
    /// values cannot be read.
    private static func seedSanDataWithMToonSpecVersion(_ specVersion: String,
                                                        isRequired: Bool) throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "mtoon-spec-\(specVersion)") { json in
            if isRequired {
                json["extensionsRequired"] = (json["extensionsRequired"] as? [String] ?? [])
                    + ["VRMC_materials_mtoon"]
            }
            guard var materials = json["materials"] as? [[String: Any]],
                  var extensions = materials.first?["extensions"] as? [String: Any],
                  var mtoon = extensions["VRMC_materials_mtoon"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon extension")
            }
            mtoon["specVersion"] = specVersion
            extensions["VRMC_materials_mtoon"] = mtoon
            materials[0]["extensions"] = extensions
            json["materials"] = materials
        }
    }

    /// A VRM material without MToon data, which would fall back to Unlit / PBR
    /// under the default chain, converts too, and the expression runtime picks
    /// the converted parameters up.
    @Test
    func testConvertAllAppliesToVRMMaterialsWithoutMToonData() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let stripped = try TestSupport.modifiedSeedSanMaterial(name: "no-mtoon-extension") { material in
            var extensions = material["extensions"] as? [String: Any] ?? [:]
            extensions.removeValue(forKey: "VRMC_materials_mtoon")
            material["extensions"] = extensions
        }

        let fallbackEntity = try VRMEntityLoader(withData: stripped,
                                                 shaders: [MToonShader()]).loadEntity()
        #expect(fallbackEntity.mtoonParameters(forMaterialIndex: 0) == nil)

        let loader = try VRMEntityLoader(withData: stripped,
                                         shaders: [MToonShader(source: .convertAll)])
        let convertedEntity = try loader.loadEntity()
        #expect(try loader.material(withMaterialIndex: 0) is CustomMaterial)
        #expect(convertedEntity.mtoonParameters(forMaterialIndex: 0) != nil)
    }
#endif
}
#endif
