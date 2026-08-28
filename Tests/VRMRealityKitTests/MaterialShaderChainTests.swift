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
    func testCustomShaderTakesOverMaterialBuilding() async throws {
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
        let entity = try await loader.loadEntity()

        #expect(shader.seenMaterialIndices == [0])
        for modelEntity in entity.modelEntitiesInHierarchy {
            let materials = modelEntity.components[ModelComponent.self]?.materials ?? []
            #expect(materials.allSatisfy { $0 is UnlitMaterial })
        }
    }

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

    /// The mechanism MToon's outline pass is drawn through.
    @Test
    func testAdditionalPassesBecomeSiblingModelEntities() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        final class TwoPassShader: GLTFMaterialShader {
            func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
                GLTFShadedMaterial(material: UnlitMaterial(),
                                   additionalPasses: [.init(material: UnlitMaterial(), name: "halo")])
            }
        }

        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [TwoPassShader()]).loadEntity()
        let modelEntities = entity.modelEntitiesInHierarchy
        #expect(modelEntities.count == 2)
        #expect(modelEntities.contains { $0.name.hasSuffix("_halo") })
        // Both passes share the material index, so runtime updates reach them together.
        #expect(modelEntities.allSatisfy {
            $0.components[GLTFMaterialIndexComponent.self]?.materialIndex == 0
        })
    }

    /// A custom shader's animatable state is driven end to end by VRM expression
    /// material binds the way MToon's is: baselines at load, `setColor`
    /// accumulation, one `prepareFlush()` per change, then `apply(to:)`.
    @Test
    func testCustomAnimatingShaderIsDrivenByExpressionBinds() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let target = SIMD4<Float>(0, 1, 0, 1)
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "custom-shader-color-bind") { preset in
            guard var happy = preset.object("happy") else {
                throw VRMError.dataInconsistent("Missing Seed-san happy expression")
            }
            happy["materialColorBinds"] = [[
                "material": 0,
                "type": "color",
                "targetValue": [0.0, 1.0, 0.0, 1.0]
            ]]
            preset["happy"] = .object(happy)
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
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: [shader]).loadEntity()
        // Material bindings register while meshes build, so the first state per
        // index is the one the entity holds.
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
    func testUnclaimedBindsFallBackToTheRealityKitMaterial() async throws {
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

        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                                  shaders: [ColorOnlyShader()]).loadEntity()
        vrmEntity.setExpression(value: 1, for: .preset(.happy))

        let transforms = vrmEntity.modelEntitiesInHierarchy
            .filter { $0.components[GLTFMaterialIndexComponent.self]?.materialIndex == 11 }
            .flatMap { $0.components[ModelComponent.self]?.materials ?? [] }
            .compactMap { ($0 as? UnlitMaterial)?.textureCoordinateTransform }
        #expect(!transforms.isEmpty)
        #expect(transforms.allSatisfy { $0.offset.isApproximatelyEqual(to: SIMD2<Float>(0.25, 0)) })
    }

    /// A VRM material the chain fails to build renders with the default material,
    /// and the chain is not asked a second time, so the runtime state can never
    /// come from a material that is not on screen.
    @Test
    func testFailedVRMMaterialFallsBackOnceAndCarriesNoAnimatableState() async throws {
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
        let entity = try await loader.loadEntity()

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
    func testUnbuildableMToonMaterialFallsThroughWhenTheExtensionIsOptional() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: Self.brokenMToonSeedSanData(isRequired: false))
        _ = try await loader.loadEntity()
        #expect(try loader.material(withMaterialIndex: 0) is UnlitMaterial)
    }

    /// A generic glTF load honors `extensionsRequired`, so a document that cannot
    /// be drawn without `VRMC_materials_mtoon` fails rather than approximating.
    @Test
    func testUnbuildableMToonMaterialFailsTheGLTFLoadWhenTheExtensionIsRequired() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withData: Self.brokenMToonSeedSanData(isRequired: true))
        await #expect(throws: (any Error).self) {
            try await loader.loadEntity()
        }
    }

    /// A VRM honors `extensionsRequired` too, so the material MToon could not build renders
    /// as the default material rather than an approximation.
    @Test
    func testUnbuildableRequiredMToonMaterialFallsBackToTheDefaultMaterialInAVRM() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: Self.brokenMToonSeedSanData(isRequired: true))
        let entity = try await loader.loadEntity()
        #expect(try loader.material(withMaterialIndex: 0) is PhysicallyBasedMaterial)
        // The rest of the model still renders as MToon.
        #expect(TestSupport.hasCustomMaterial(in: entity))
    }

    /// The loader's check only sees the core glTF material's textures, so MToon
    /// itself rejects a document requiring `KHR_texture_transform` while giving its
    /// own textures different transforms.
    @Test
    func testRequiredTextureTransformFailsWhenMToonTexturesDisagree() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "mixed-mtoon-texture-transform") { json in
            json["extensionsRequired"] = .strings(json.strings("extensionsRequired")
                + ["KHR_texture_transform"])
            var materials = json.objects("materials")
            guard var extensions = materials.first?.object("extensions"),
                  var mtoon = extensions.object("VRMC_materials_mtoon"),
                  var shade = mtoon.object("shadeMultiplyTexture") else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon shade texture")
            }
            // The core material's textures still agree, so only MToon's own
            // texture set makes the transforms disagree.
            shade["extensions"] = ["KHR_texture_transform": ["scale": [2.0, 2.0]]]
            mtoon["shadeMultiplyTexture"] = .object(shade)
            extensions["VRMC_materials_mtoon"] = .object(mtoon)
            materials[0]["extensions"] = .object(extensions)
            json["materials"] = .objects(materials)
        }

        await #expect(throws: (any Error).self) {
            try await GLTFEntityLoader(withData: modified).loadEntity()
        }
        // A VRM is held to the same requirement.
        #expect(try VRMEntityLoader(withData: modified).material(withMaterialIndex: 0)
            is PhysicallyBasedMaterial)
    }

    /// Seed-san with material 0's MToon shade texture pointing past the end of
    /// the texture array, so building it as MToon fails.
    private static func brokenMToonSeedSanData(isRequired: Bool) throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "broken-mtoon-texture-\(isRequired ? "required" : "used")") { json in
            if isRequired {
                json["extensionsRequired"] = .strings(json.strings("extensionsRequired")
                    + ["VRMC_materials_mtoon"])
            }
            var materials = json.objects("materials")
            guard var extensions = materials.first?.object("extensions"),
                  var mtoon = extensions.object("VRMC_materials_mtoon") else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon extension")
            }
            mtoon["shadeMultiplyTexture"] = ["index": 9999]
            extensions["VRMC_materials_mtoon"] = .object(mtoon)
            materials[0]["extensions"] = .object(extensions)
            json["materials"] = .objects(materials)
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

    /// `.authoredOnly` is the default source.
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
    func testConvertAllWithOutlineStyleCreatesOutlineEntities() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let passName = MToonShader.outlinePassName
        func outlines(in root: Entity) -> [ModelEntity] {
            root.modelEntitiesInHierarchy.filter {
                $0.components[GLTFMaterialPassComponent.self]?.name == passName
            }
        }
        // Named after the mesh it belongs to, not after the unnamed model entity.
        let outline = try #require(outlines(in: entity).first)
        let mesh = try #require(outline.parent?.parent)
        #expect(!mesh.name.isEmpty)
        #expect(outline.name == "\(mesh.name)_\(passName)")
        #expect(outline.parent?.name == "\(mesh.name)_container")

        let noOutline = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                   shaders: [MToonShader(source: .convertAll)]).loadEntity()
        #expect(outlines(in: noOutline).isEmpty)
    }

    @Test
    func testConvertAllKeepsAuthoredMToonMaterials() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func shadeColor(of loader: any MaterialInspectingLoader) throws -> SIMD4<Float> {
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
    /// the Unlit approximation rather than inventing toon values over it.
    @Test
    func testConvertAllLeavesUnreadableMToonVersionsAlone() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let futureVersion = try Self.seedSanDataWithMToonSpecVersion("1.1", isRequired: false)

        for source in [MToonShader.Source.authoredOnly, .convertAll] {
            let loader = try VRMEntityLoader(withData: futureVersion,
                                             shaders: [MToonShader(source: source)])
            let entity = try await loader.loadEntity()
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
    func testUnreadableMToonVersionFailsTheGLTFLoadWhenTheExtensionIsRequired() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let required = try Self.seedSanDataWithMToonSpecVersion("1.1", isRequired: true)
        await #expect(throws: (any Error).self) {
            try await GLTFEntityLoader(withData: required).loadEntity()
        }
        // A VRM is held to the same requirement.
        let vrmLoader = try VRMEntityLoader(withData: required)
        _ = try await vrmLoader.loadEntity()
        #expect(try vrmLoader.material(withMaterialIndex: 0) is PhysicallyBasedMaterial)
    }

    /// Seed-san with material 0's MToon `specVersion` replaced, so its authored
    /// values cannot be read.
    private static func seedSanDataWithMToonSpecVersion(_ specVersion: String,
                                                        isRequired: Bool) throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "mtoon-spec-\(specVersion)") { json in
            if isRequired {
                json["extensionsRequired"] = .strings(json.strings("extensionsRequired")
                    + ["VRMC_materials_mtoon"])
            }
            var materials = json.objects("materials")
            guard var extensions = materials.first?.object("extensions"),
                  var mtoon = extensions.object("VRMC_materials_mtoon") else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon extension")
            }
            mtoon["specVersion"] = .string(specVersion)
            extensions["VRMC_materials_mtoon"] = .object(mtoon)
            materials[0]["extensions"] = .object(extensions)
            json["materials"] = .objects(materials)
        }
    }

    /// A VRM material without MToon data, which would fall back to Unlit / PBR
    /// under the default chain, converts too, and the expression runtime picks
    /// the converted parameters up.
    @Test
    func testConvertAllAppliesToVRMMaterialsWithoutMToonData() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let stripped = try TestSupport.modifiedSeedSanMaterial(name: "no-mtoon-extension") { material in
            var extensions = material.object("extensions") ?? [:]
            extensions.removeValue(forKey: "VRMC_materials_mtoon")
            material["extensions"] = .object(extensions)
        }

        let fallbackEntity = try await VRMEntityLoader(withData: stripped,
                                                       shaders: [MToonShader()]).loadEntity()
        #expect(fallbackEntity.mtoonParameters(forMaterialIndex: 0) == nil)

        let loader = try VRMEntityLoader(withData: stripped,
                                         shaders: [MToonShader(source: .convertAll)])
        let convertedEntity = try await loader.loadEntity()
        #expect(try loader.material(withMaterialIndex: 0) is CustomMaterial)
        #expect(convertedEntity.mtoonParameters(forMaterialIndex: 0) != nil)
    }
#endif
}
#endif
