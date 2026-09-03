#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// How the MToon shader builds and updates the materials a VRM renders with:
/// the parameter texture rows, the shader constants they agree on, and what a
/// platform or an unbuildable material falls back to instead.
@Suite
@MainActor
struct MToonRenderingTests {

#if !os(visionOS)
    @Test
    func testVRM1MToonCustomMaterialUsesParameterTexture() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let customMaterial = try #require(material as? CustomMaterial,
                                          TestSupport.expectedCustomMaterialMessage)

        #expect(customMaterial.custom.texture != nil)
        #expect(customMaterial.normal.texture != nil)
        #expect(customMaterial.roughness.texture != nil)
        #expect(customMaterial.emissiveColor.texture != nil)
        #expect(customMaterial.clearcoatRoughness.texture != nil)
        // The outline-width map rides on clearcoat, which only the outline
        // pass's geometry modifier samples, so the main material leaves it free.
        #expect(customMaterial.clearcoat.texture == nil)

        // The light direction rides in the parameter texture; custom.value only
        // carries the tone-mapping compensation flag (on by default) and the
        // outline budget.
        #expect(customMaterial.custom.value.isApproximatelyEqual(to: SIMD4<Float>(1, 0, 0, 0)))
    }

    @Test
    func testVRM1MToonRenderingCanBeDisabled() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let defaultLoader = try VRMEntityLoader(withData: seedSan)
        let defaultMaterial = try defaultLoader.material(withMaterialIndex: 0)
        _ = try #require(defaultMaterial as? CustomMaterial,
                         TestSupport.expectedCustomMaterialMessage)

        let disabledLoader = try VRMEntityLoader(withData: seedSan, shaders: [])
        let disabledMaterial = try disabledLoader.material(withMaterialIndex: 0)
        #expect(!(disabledMaterial is CustomMaterial))
        #expect(disabledMaterial is UnlitMaterial)

        let disabledEntity = try await disabledLoader.loadEntity()
        #expect(!TestSupport.hasCustomMaterial(in: disabledEntity))
        #expect(!TestSupport.hasMToonParameters(in: disabledEntity))
    }

    @Test
    func testMToonParameterTextureRowsMatchMetalConstant() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmLoader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let parameters = try TestSupport.mtoonParameters(of: vrmLoader, materialIndex: 0)
        let texture = try parameters.textureResource()
        let shader = TestSupport.mtoonShaderSource

        #expect(MToonMaterialParameters.baseParameterRowCount == 18)
        #expect(MToonMaterialParameters.samplerRowCount == MToonTextureSlot.allCases.count)
        #expect(MToonMaterialParameters.textureRowCount == 27)
        #expect(parameters.samplers.count == MToonMaterialParameters.samplerRowCount)
        #expect(texture.width == MToonMaterialParameters.textureRowCount)
        #expect(texture.height == 1)

        // Extracted rather than restated, so any reordering or insertion on
        // either side fails here.
        let shaderConstants = shaderFloatConstants(in: shader)
        #expect(shaderConstants["mtoonParameterTextureWidth"] == Float(MToonMaterialParameters.textureRowCount))
        #expect(shaderConstants["mtoonSamplerParameterStart"] == Float(MToonMaterialParameters.baseParameterRowCount))
        for row in MToonParameterRow.allCases {
            let name = shaderConstantName(prefix: "mtoonRow", case: row)
            #expect(shaderConstants[name] == Float(row.rawValue),
                    "Shader constant \(name) does not match MToonParameterRow.\(row) (\(row.rawValue)).")
        }
        for slot in MToonTextureSlot.allCases {
            let name = shaderConstantName(prefix: "mtoonSamplerSlot", case: slot)
            #expect(shaderConstants[name] == Float(slot.rawValue),
                    "Shader constant \(name) does not match MToonTextureSlot.\(slot) (\(slot.rawValue)).")
        }
    }

    @Test
    func testMToonNormalScaleIsPassedToShaderParameters() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "normal-scale") { material in
            material["normalTexture"] = ["index": 0, "scale": 0.35]
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let parameters = try TestSupport.mtoonParameters(of: loader, materialIndex: 0)

        #expect(parameters.normalParameters.x.isApproximatelyEqual(to: 0.35))
    }

    @Test
    func testMToonSkipsWorkThatCannotContribute() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san material 0 ("hair") has an outlineWidthMultiplyTexture; 1
        // ("huku_bake") does not, so the flag must differ between them.
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        #expect(try TestSupport.mtoonParameters(of: loader, materialIndex: 0).outlineParams.w == 1)
        #expect(try TestSupport.mtoonParameters(of: loader, materialIndex: 1).outlineParams.w == 0)
    }

    @Test
    func testMToonMaskTextureSlotsUseRawSemantic() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let textureIndex = 0
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "raw-mask-textures") { mtoon in
            mtoon["shadingShiftTexture"] = ["index": .int(textureIndex)]
            mtoon["outlineWidthMultiplyTexture"] = ["index": .int(textureIndex)]
            mtoon["uvAnimationMaskTexture"] = ["index": .int(textureIndex)]
        }

        let loader = try VRMEntityLoader(withData: modified)
        let shaded = try loader.shadedMaterial(withMaterialIndex: 0)
        let material = try #require(shaded.material as? CustomMaterial)
        let rawTexture = try loader.texture(withTextureIndex: textureIndex, semantic: .raw)
        let colorTexture = try loader.texture(withTextureIndex: textureIndex, semantic: .color)

        #expect(material.specular.texture != nil)
        #expect(material.ambientOcclusion.texture != nil)
        // The outline-width map is sampled by the outline pass alone, so that is
        // the material carrying it.
        let outline = try #require(shaded.additionalPasses.first?.material as? CustomMaterial)
        #expect(outline.clearcoat.texture != nil)
        #expect(MToonTextureSlot.shadingShift.semantic == .raw)
        #expect(MToonTextureSlot.outlineWidth.semantic == .raw)
        #expect(MToonTextureSlot.uvAnimationMask.semantic == .raw)
        #expect(rawTexture !== colorTexture)
    }

    @Test
    func testMToonEmissiveFlagFactorAndEmissionColorBind() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmLoader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        var parameters = try TestSupport.mtoonParameters(of: vrmLoader, materialIndex: 0)
        let boundColor = SIMD4<Float>(0.25, 0.5, 0.75, 0.2)

        #expect(parameters.extraFlags.z == 0 || parameters.extraFlags.z == 1)
        #expect(parameters.color(for: .emissionColor).isApproximatelyEqual(to: parameters.emissiveFactor))
        parameters.setColor(boundColor, for: .emissionColor)
        #expect(parameters.emissiveFactor.isApproximatelyEqual(to: SIMD4<Float>(0.25, 0.5, 0.75, 1)))
        #expect(parameters.color(for: .emissionColor).isApproximatelyEqual(to: parameters.emissiveFactor))
    }

    @Test
    func testMToonShadeMultiplyTextureFallsBackToWhite() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try seedSanDataWithNonDefaultEyeSampler()
        let vrmLoader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let eyeTransparentParameters = try TestSupport.mtoonParameters(of: vrmLoader, materialIndex: 4)

        #expect(eyeTransparentParameters.samplers[MToonTextureSlot.base.rawValue] != MToonMaterialParameters.defaultSampler)
        #expect(eyeTransparentParameters.samplers[MToonTextureSlot.shade.rawValue] == MToonMaterialParameters.defaultSampler)
    }

    @Test
    func testMToonRespectsDoubleSidedMaterialFlag() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let singleSidedLoader = try VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders)
        let singleSided = try #require(singleSidedLoader.material(withMaterialIndex: 0) as? CustomMaterial)
        #expect(singleSided.faceCulling == .back)

        let doubleSidedData = try TestSupport.modifiedSeedSanMaterial(name: "double-sided") { material in
            material["doubleSided"] = true
        }

        let doubleSidedLoader = try VRMEntityLoader(withData: doubleSidedData, shaders: TestSupport.noOutlineShaders)
        let doubleSided = try #require(doubleSidedLoader.material(withMaterialIndex: 0) as? CustomMaterial)
        #expect(doubleSided.faceCulling == .none)
    }

    @Test
    func testTransparentOutlinePreservesBaseTextureAlpha() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "transparent-outline") { material in
            material["alphaMode"] = "BLEND"
            var pbr = material.object("pbrMetallicRoughness") ?? [:]
            pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 0.5]
            material["pbrMetallicRoughness"] = .object(pbr)
        }

        let loader = try VRMEntityLoader(withData: modified)
        let vrmEntity = try await loader.loadEntity()
        let outline = try customMaterial(in: vrmEntity,
                                         materialIndex: 0,
                                         faceCulling: .front)
        #expect(TestSupport.isTransparent(outline.blending))
        #expect(outline.baseColor.texture != nil)

    }

    @Test
    func testMToonUsesFirstUVTransformWhenTextureSlotsDiffer() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "different-uv-transforms") { material in
            guard var pbr = material.object("pbrMetallicRoughness"),
                  var baseTexture = pbr.object("baseColorTexture"),
                  var extensions = material.object("extensions"),
                  var mtoon = extensions.object("VRMC_materials_mtoon"),
                  var shadeTexture = mtoon.object("shadeMultiplyTexture") else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon texture fixture data")
            }
            baseTexture["texCoord"] = 1
            baseTexture["extensions"] = [
                "KHR_texture_transform": [
                    "offset": [0.25, 0.5],
                    "scale": [0.75, 0.5],
                    "rotation": 0.2,
                    "texCoord": 1
                ]
            ]
            pbr["baseColorTexture"] = .object(baseTexture)
            material["pbrMetallicRoughness"] = .object(pbr)

            shadeTexture["extensions"] = [
                "KHR_texture_transform": [
                    "offset": [0.9, 0.8],
                    "scale": [0.4, 0.3]
                ]
            ]
            mtoon["shadeMultiplyTexture"] = .object(shadeTexture)
            extensions["VRMC_materials_mtoon"] = .object(mtoon)
            material["extensions"] = .object(extensions)
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let material = try #require(loader.material(withMaterialIndex: 0) as? CustomMaterial)
        let transform = try #require(loader.makeAnimatableMaterialState(forMaterialIndex: 0)?.textureTransform)
        #expect(transform.offset.isApproximatelyEqual(to: SIMD2<Float>(0.25, 0.5)))
        #expect(transform.scale.isApproximatelyEqual(to: SIMD2<Float>(0.75, 0.5)))
        #expect(transform.rotation.isApproximatelyEqual(to: 0.2))
        // MToon.metal applies the transform from the parameter rows, so the
        // material-level transform must stay identity, otherwise RealityKit
        // would transform the primary UV a second time.
        #expect(material.textureCoordinateTransform.offset == SIMD2<Float>(0, 0))
        #expect(material.textureCoordinateTransform.scale == SIMD2<Float>(1, 1))
        #expect(material.textureCoordinateTransform.rotation == 0)
    }

    @Test
    func testMToonKeepsAnIdentityTransformWhenOnlyALaterSlotHasOne() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "shade-only-uv-transform") { mtoon in
            guard var shadeTexture = mtoon.object("shadeMultiplyTexture") else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon texture fixture data")
            }
            shadeTexture["extensions"] = [
                "KHR_texture_transform": [
                    "offset": [0.9, 0.8],
                    "scale": [0.4, 0.3]
                ]
            ]
            mtoon["shadeMultiplyTexture"] = .object(shadeTexture)
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        _ = try #require(loader.material(withMaterialIndex: 0) as? CustomMaterial)

        // Base color is the first UV-accessed slot, so its identity transform
        // wins; taking the first non-nil transform instead would apply the
        // shade slot's transform to the base color texture.
        let transform = try #require(loader.makeAnimatableMaterialState(forMaterialIndex: 0)?.textureTransform)
        #expect(transform.offset == SIMD2<Float>(0, 0))
        #expect(transform.scale == SIMD2<Float>(1, 1))
        #expect(transform.rotation == 0)
    }

    /// The light direction and the light color each ride in their own parameter
    /// row, so updating one must not drop the other.
    @Test
    func testMToonLightColorUpdateKeepsTheCustomLightDirection() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmLoader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try await vrmLoader.loadEntity()

        vrmEntity.setMToonLightDirection(SIMD3<Float>(0, 0, -2))
        vrmEntity.setMToonLightColor(SIMD3<Float>(0.8, 0.7, 0.6))

        let parameters = try firstMToonParameters(in: vrmEntity)
        #expect(parameters.lightColor.isApproximatelyEqual(to: SIMD4<Float>(0.8, 0.7, 0.6, 1)))
        #expect(parameters.lightDirection.isApproximatelyEqual(to: SIMD3<Float>(0, 0, -1)))
    }

    @Test
    func testSetMToonLightAndAmbientColorUpdateParameterRows() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try await vrmLoader.loadEntity()
        let lightColor = SIMD3<Float>(0.8, 0.7, 0.6)
        let ambientColor = SIMD3<Float>(0.05, 0.1, 0.15)

        vrmEntity.setMToonLightColor(lightColor)
        vrmEntity.setMToonAmbientColor(ambientColor)

        let parameters = try firstMToonParameters(in: vrmEntity)
        #expect(parameters.lightColor.isApproximatelyEqual(to: SIMD4<Float>(0.8, 0.7, 0.6, 1)))
        #expect(parameters.ambientColor.isApproximatelyEqual(to: SIMD4<Float>(0.05, 0.1, 0.15, 1)))
        let material = try firstCustomMaterial(in: vrmEntity)
        #expect(material.custom.texture != nil)
    }

    @Test
    func testMToonTextureTransformBindUpdatesParameterTexture() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await vrmLoader.loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.happy))

        let parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.25, 0)))
        #expect(parameters.uvTransformRotation.isApproximatelyEqual(to: SIMD4<Float>(1, 0, 0, 0)))
        // The parameter rows are the only UV-transform source for MToon; the
        // material-level transform stays identity so the shader applies it once.
        let material = try customMaterial(in: vrmEntity, materialIndex: 11)
        #expect(material.textureCoordinateTransform.offset == SIMD2<Float>(0, 0))
        #expect(material.textureCoordinateTransform.scale == SIMD2<Float>(1, 1))
    }

    /// Metallib freshness is checked by scripts/build-mtoon-metallibs.sh --check
    /// (which CI runs), so this only covers what the bundle itself must contain.
    @Test
    func testBundledMToonMetallibsArePackagedWithoutShaderSource() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // The same bundle the loader itself reads from.
        let bundle = MToonShaderLibraryLoader.resourceBundle

        // Shader source must never ship as a bundle resource (App Store safety).
        #expect(bundle.url(forResource: "MToon", withExtension: "metal") == nil)
        #expect(bundle.url(forResource: "MToonCore", withExtension: "h") == nil)

        for resourceName in ["MToon-macos", "MToon-ios", "MToon-iossim"] {
            #expect(bundle.url(forResource: resourceName, withExtension: "metallib") != nil,
                    "Missing bundled metallib: \(resourceName).metallib. Run scripts/build-mtoon-metallibs.sh.")
        }
    }

    @Test
    func testBundledMToonLibraryCanBeLoadedOnSupportedPlatforms() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
#if targetEnvironment(macCatalyst)
        // Mac Catalyst intentionally bundles no metallib.
        #expect(MToonShaderLibraryLoader.resourceName == nil)
#else
        // On supported platforms this must hard-fail instead of skipping when
        // the bundled metallib cannot be loaded.
        let device = try #require(MTLCreateSystemDefaultDevice(), "A Metal device is required to run this test.")
        let library = try MToonShaderLibraryLoader.load(device: device)
        let functions = Set(library.functionNames)

        #expect(functions.contains("mtoonSurface"))
        #expect(functions.contains("mtoonOutlineSurface"))
        #expect(functions.contains("mtoonOutlineGeometry"))
#endif
    }

    @Test
    func testMToonShadeColorBindDoesNotOverwriteCustomLightDirection() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let material = try vrmLoader.material(withMaterialIndex: 0)
        let customMaterial = try #require(material as? CustomMaterial,
                                          TestSupport.expectedCustomMaterialMessage)
        let initialValue = customMaterial.custom.value

        let updatedMaterial = customMaterial.settingColor(VRMColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                                                          for: .shadeColor)
        let updatedCustomMaterial = try #require(updatedMaterial as? CustomMaterial)

        #expect(updatedCustomMaterial.custom.value == initialValue)
    }

    @Test
    func testMToonSamplerKeepsMagAndMinFiltersIndependent() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // glTF magFilter and minFilter are independent, so a LINEAR magFilter
        // must stay linear next to a NEAREST minFilter.
        // Material 0's base color texture uses sampler 0.
        let modified = try TestSupport.modifiedSeedSanData(name: "mixed-filter-sampler") { json in
            var samplers = json.objects("samplers")
            guard !samplers.isEmpty else {
                throw VRMError.dataInconsistent("Missing Seed-san sampler fixture data")
            }
            samplers[0]["magFilter"] = 9729                 // LINEAR
            samplers[0]["minFilter"] = 9728                 // NEAREST
            samplers[0]["wrapS"] = 33071                    // CLAMP_TO_EDGE
            samplers[0]["wrapT"] = 33648                    // MIRRORED_REPEAT
            json["samplers"] = .objects(samplers)
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let parameters = try TestSupport.mtoonParameters(of: loader, materialIndex: 0)

        // (wrapS, wrapT, filterIndex, 0): clamp / mirrored repeat, and a
        // magnification filter that stays linear while minification is nearest.
        let filter = MToonSamplerFilter(magnification: .linear, minification: .nearest, mip: .none)
        #expect(parameters.samplers[MToonTextureSlot.base.rawValue]
            .isApproximatelyEqual(to: SIMD4<Float>(1, 2, Float(filter.index), 0)))
        // Untouched slots keep the glTF defaults: repeat/repeat, linear
        // magnification, trilinear minification.
        #expect(MToonMaterialParameters.defaultSampler
            == SIMD4<Float>(0, 0, Float(MToonSamplerFilter.default.index), 0))
        #expect(MToonSamplerFilter.default.magnification == .linear)
        #expect(MToonSamplerFilter.default.minification == .linear)
        #expect(MToonSamplerFilter.default.mip == .linear)
    }

    @Test
    func testEveryGLTFMinFilterMapsToADistinctSampler() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // glTF's six minFilter values are two independent choices, the
        // minification texel filter and the filter between mip levels, so each
        // has to encode to its own filter index.
        let minFilters: [(raw: Int, minification: MToonSamplerFilter.TexelFilter, mip: MToonSamplerFilter.MipFilter)] = [
            (9728, .nearest, .none),      // NEAREST
            (9729, .linear, .none),       // LINEAR
            (9984, .nearest, .nearest),   // NEAREST_MIPMAP_NEAREST
            (9985, .linear, .nearest),    // LINEAR_MIPMAP_NEAREST
            (9986, .nearest, .linear),    // NEAREST_MIPMAP_LINEAR
            (9987, .linear, .linear)      // LINEAR_MIPMAP_LINEAR
        ]

        var seenIndexes: Set<Int> = []
        for entry in minFilters {
            let modified = try TestSupport.modifiedSeedSanData(name: "min-filter-\(entry.raw)") { json in
                var samplers = json.objects("samplers")
                guard !samplers.isEmpty else {
                    throw VRMError.dataInconsistent("Missing Seed-san sampler fixture data")
                }
                samplers[0]["minFilter"] = .int(entry.raw)
                json["samplers"] = .objects(samplers)
            }
            let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
            let parameters = try TestSupport.mtoonParameters(of: loader, materialIndex: 0)
            let expected = MToonSamplerFilter(magnification: .linear,
                                              minification: entry.minification,
                                              mip: entry.mip)
            #expect(parameters.samplers[MToonTextureSlot.base.rawValue].z
                .isApproximatelyEqual(to: Float(expected.index)),
                    "glTF minFilter \(entry.raw) mapped to the wrong sampler")
            seenIndexes.insert(expected.index)
        }
        #expect(seenIndexes.count == minFilters.count)
        #expect(MToonSamplerFilter.count == 12)
    }

    @Test
    func testTransparentWithZWriteControlsDepthWriting() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func customMaterial(alphaMode: String, transparentWithZWrite: Bool) throws -> CustomMaterial {
            let modified = try TestSupport.modifiedSeedSanMaterial(name: "z-write-\(alphaMode)-\(transparentWithZWrite)") { material in
                material["alphaMode"] = .string(alphaMode)
                guard var extensions = material.object("extensions"),
                      var mtoon = extensions.object("VRMC_materials_mtoon") else {
                    throw VRMError.dataInconsistent("Missing Seed-san MToon extension")
                }
                mtoon["transparentWithZWrite"] = .bool(transparentWithZWrite)
                extensions["VRMC_materials_mtoon"] = .object(mtoon)
                material["extensions"] = .object(extensions)
            }
            let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
            return try #require(loader.material(withMaterialIndex: 0) as? CustomMaterial,
                                TestSupport.expectedCustomMaterialMessage)
        }

        // Only a blended material may stop writing depth.
        #expect(try !customMaterial(alphaMode: "BLEND", transparentWithZWrite: false).writesDepth)
        #expect(try customMaterial(alphaMode: "BLEND", transparentWithZWrite: true).writesDepth)
        #expect(try customMaterial(alphaMode: "OPAQUE", transparentWithZWrite: false).writesDepth)
        #expect(try customMaterial(alphaMode: "MASK", transparentWithZWrite: false).writesDepth)
    }

    @Test
    func testUpdateDoesNotMutateMToonMaterialsPerFrame() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try await vrmLoader.loadEntity()
        let initialValue = try firstCustomMaterial(in: vrmEntity).custom.value

        vrmEntity.update(deltaTime: 0.25)
        vrmEntity.update(deltaTime: 0.5)

        // UV animation time comes from params.uniforms().time() on the GPU;
        // update() must not touch MToon materials at all.
        let afterUpdateValue = try firstCustomMaterial(in: vrmEntity).custom.value
        #expect(afterUpdateValue == initialValue)
    }

    @Test
    func testSetMToonLightDirectionUpdatesParameterRows() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try await vrmLoader.loadEntity()
        let writesBefore = mtoonParameterWriteCounts(in: vrmEntity)

        // The direction is normalized before it reaches the parameter rows, and
        // rides there rather than in the materials: tracking a light per frame
        // rewrites no ModelComponent.
        vrmEntity.setMToonLightDirection(SIMD3<Float>(0, 0, -2))

        var checkedStates = 0
        for index in vrmEntity.materialStates.keys {
            guard let state = vrmEntity.mtoonState(forMaterialIndex: index) else { continue }
            #expect(state.parameters.lightDirection.isApproximatelyEqual(to: SIMD3<Float>(0, 0, -1)))
            checkedStates += 1
        }
        #expect(checkedStates > 0)
        #expect(mtoonParameterWriteCounts(in: vrmEntity) != writesBefore)

        // The materials still hold the shared parameter texture; custom.value
        // carries only the renderer's tone-mapping flag and the outline budget.
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let model = modelEntity.components[ModelComponent.self] else { continue }
            let isOutlinePass = modelEntity.components.has(GLTFMaterialPassComponent.self)
            for material in model.materials.compactMap({ $0 as? CustomMaterial }) {
                let value = material.custom.value
                #expect(value.x == 1)
                #expect(SIMD2<Float>(value.y, value.z) == .zero)
                #expect(isOutlinePass ? value.w > 0 : value.w == 0)
                #expect(material.custom.texture != nil)
            }
        }
    }

    @Test
    func testCompensatesToneMappingFlagReachesCustomValue() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData,
                                         shaders: [MToonShader(compensatesToneMapping: false)])
        let vrmEntity = try await loader.loadEntity()

        var checkedMaterials = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let model = modelEntity.components[ModelComponent.self] else { continue }
            for material in model.materials.compactMap({ $0 as? CustomMaterial }) {
                #expect(material.custom.value.x == 0)
                checkedMaterials += 1
            }
        }
        #expect(checkedMaterials > 0)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func mtoonParameterWriteCounts(in entity: VRMEntity) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for index in entity.materialStates.keys {
            counts[index] = entity.mtoonState(forMaterialIndex: index)?.parameterTexture?.writeCount
        }
        return counts
    }

    @Test
    func testMalformedMaterialColorBindDoesNotFailModelLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "malformed-color-bind") { json in
            guard var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRMC_vrm"),
                  var expressions = vrm.object("expressions"),
                  var preset = expressions.object("preset"),
                  var happy = preset.object("happy") else {
                throw VRMError.dataInconsistent("Missing Seed-san expression fixture data")
            }
            happy["materialColorBinds"] = [
                [
                    "material": 9999,
                    "type": "color",
                    "targetValue": [1.0, 0.0, 0.0, 1.0]
                ],
                [
                    "material": 0,
                    "type": "color",
                    "targetValue": [0.5, 1.0, 1.0, 1.0]
                ]
            ]
            preset["happy"] = .object(happy)
            expressions["preset"] = .object(preset)
            vrm["expressions"] = .object(expressions)
            extensions["VRMC_vrm"] = .object(vrm)
            json["extensions"] = .object(extensions)
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        // The invalid bind is skipped while the valid one keeps working.
        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        let parameters = try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.x.isApproximatelyEqual(to: 0.5))
    }

    /// A malformed MToon extension is a rendering limitation, not a broken file:
    /// the material falls back to Unlit / PBR and the model still loads.
    @Test
    func testMToonExtensionWithAnInvalidTextureFallsBackInsteadOfFailingTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "mtoon-texture-out-of-range") { mtoon in
            mtoon["shadeMultiplyTexture"] = ["index": 9999]
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        // The state goes with the material, so no expression bind keeps writing
        // parameter rows no shader reads.
        #expect(vrmEntity.mtoonParameters(forMaterialIndex: 0) == nil)
        #expect(!TestSupport.modelEntities(in: vrmEntity).isEmpty)
    }

    /// One unbuildable material must cost that primitive its material, not the
    /// whole model.
    @Test
    func testMaterialThatCannotBeBuiltFallsBackToTheDefaultMaterial() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "base-texture-out-of-range") { material in
            // Without the MToon extension the material takes the Unlit / PBR
            // path, where an out-of-range base color texture throws.
            material["extensions"] = .object([:])
            material["pbrMetallicRoughness"] = ["baseColorTexture": ["index": 9999]]
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        #expect(TestSupport.materialIndexes(in: vrmEntity).contains(0))
        #expect(!TestSupport.modelEntities(in: vrmEntity).isEmpty)
    }

    @Test
    func testFallbackMaterialsDoNotCarryMToonRuntimeState() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let loader = try VRMEntityLoader(withData: seedSan, shaders: [])
        let vrmEntity = try await loader.loadEntity()

        // With MToon disabled, no entity carries MToon runtime state, and
        // expression color binds resolve through the fallback material path.
        #expect(!TestSupport.hasMToonParameters(in: vrmEntity))
        let fallbackColor = try vrmEntity.currentMaterialColor(withMaterialIndex: 0,
                                                              type: .color,
                                                              builder: loader.inspector)
        let fallbackMaterial = try loader.material(withMaterialIndex: 0)
        #expect(fallbackColor.isApproximatelyEqual(to: fallbackMaterial.currentColor(for: .color)))
    }

    @Test
    func testVRM1MToonOutlineEntitiesFollowTheOutlineOption() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let outlineEntity = try await VRMEntityLoader(withData: seedSan).loadEntity()
        #expect(hasOutlineEntities(in: outlineEntity))

        // Outlines are the inverted hull only; disabling them must not take the
        // MToon surface shader with them.
        let noOutlineEntity = try await VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders).loadEntity()
        #expect(!hasOutlineEntities(in: noOutlineEntity))
        #expect(TestSupport.hasCustomMaterial(in: noOutlineEntity))
    }

    @Test
    func testMToonMaterialsPreserveTheFixtureAlphaModes() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let opaqueMaterial = try #require(loader.material(withMaterialIndex: 0) as? CustomMaterial)
        let blendMaterial = try #require(loader.material(withMaterialIndex: 4) as? CustomMaterial)

        #expect(TestSupport.isOpaque(opaqueMaterial.blending))
        #expect(TestSupport.isTransparent(blendMaterial.blending))
    }

    /// MToon outlines are the inverted-hull entities, identified by their
    /// front-face culling rather than by an entity name.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func hasOutlineEntities(in entity: Entity) -> Bool {
        TestSupport.modelEntities(in: entity).contains { modelEntity in
            guard let model = modelEntity.components[ModelComponent.self] else { return false }
            return model.materials.contains { ($0 as? CustomMaterial)?.faceCulling == .front }
        }
    }

    /// The MToon parameters of the lowest material index that renders as MToon.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func firstMToonParameters(in vrmEntity: VRMEntity) throws -> MToonMaterialParameters {
        for materialIndex in TestSupport.materialIndexes(in: vrmEntity) {
            if let parameters = vrmEntity.mtoonParameters(forMaterialIndex: materialIndex) {
                return parameters
            }
        }
        throw VRMError.dataInconsistent("Expected at least one MToon material")
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func customMaterial(in root: Entity,
                                materialIndex: Int,
                                faceCulling: CustomMaterial.FaceCulling? = nil) throws -> CustomMaterial {
        for material in TestSupport.materials(ofMaterial: materialIndex, in: root) {
            guard let material = material as? CustomMaterial else { continue }
            if let faceCulling, material.faceCulling != faceCulling {
                continue
            }
            return material
        }
        throw VRMError.dataInconsistent("Expected CustomMaterial for material \(materialIndex)")
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func firstCustomMaterial(in root: Entity) throws -> CustomMaterial {
        for modelEntity in TestSupport.modelEntities(in: root) {
            guard let model = modelEntity.components[ModelComponent.self] else { continue }
            if let material = model.materials.first(where: { $0 is CustomMaterial }) as? CustomMaterial {
                return material
            }
        }
        throw VRMError.dataInconsistent("Expected at least one CustomMaterial")
    }

    private func shaderConstantName<Case>(prefix: String, case value: Case) -> String {
        let name = String(describing: value)
        return prefix + name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Parses `constant float <name> = <value>;` declarations out of the shader.
    private func shaderFloatConstants(in shader: String) -> [String: Float] {
        var constants: [String: Float] = [:]
        let pattern = #"constant\s+float\s+(\w+)\s*=\s*([0-9.]+)\s*;"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(shader.startIndex..<shader.endIndex, in: shader)
        regex?.enumerateMatches(in: shader, range: range) { match, _, _ in
            guard let match,
                  let nameRange = Range(match.range(at: 1), in: shader),
                  let valueRange = Range(match.range(at: 2), in: shader),
                  let value = Float(shader[valueRange]) else { return }
            constants[String(shader[nameRange])] = value
        }
        return constants
    }

    private func seedSanDataWithNonDefaultEyeSampler() throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "nondefault-eye-sampler") { json in
            var samplers = json.objects("samplers")
            guard samplers.indices.contains(7) else {
                throw VRMError.dataInconsistent("Missing Seed-san sampler fixture data")
            }
            samplers[7]["magFilter"] = 9728
            samplers[7]["minFilter"] = 9728
            samplers[7]["wrapS"] = 33071
            samplers[7]["wrapT"] = 33071
            json["samplers"] = .objects(samplers)
        }
    }
#endif

    @Test
    func testFallbackShadeAndOutlineColorBindsDoNotOverwriteBaseColor() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let baseColor = VRMColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let boundColor = VRMColor(red: 0.8, green: 0.7, blue: 0.6, alpha: 1)

        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor.tint = baseColor
        let shadeUpdatedPBR = try #require(pbr.settingColor(boundColor, for: .shadeColor) as? PhysicallyBasedMaterial)
        let outlineUpdatedPBR = try #require(pbr.settingColor(boundColor, for: .outlineColor) as? PhysicallyBasedMaterial)
        let colorUpdatedPBR = try #require(pbr.settingColor(boundColor, for: .color) as? PhysicallyBasedMaterial)

        #expect(shadeUpdatedPBR.baseColor.tint.isApproximatelyEqual(to: baseColor))
        #expect(outlineUpdatedPBR.baseColor.tint.isApproximatelyEqual(to: baseColor))
        #expect(colorUpdatedPBR.baseColor.tint.isApproximatelyEqual(to: boundColor))
        #expect(pbr.currentColor(for: .shadeColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))
        #expect(pbr.currentColor(for: .outlineColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))

        // matcapColor / rimColor are MToon-only, so on the PBR fallback they are
        // a no-op rather than being redirected onto the emissive channel.
        let emissive = VRMColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
        var emissivePBR = pbr
        emissivePBR.emissiveColor = .init(color: emissive)
        for type in [VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType.matcapColor, .rimColor] {
            let updated = try #require(emissivePBR.settingColor(boundColor, for: type) as? PhysicallyBasedMaterial)
            #expect(updated.emissiveColor.color.isApproximatelyEqual(to: emissive))
            #expect(emissivePBR.currentColor(for: type).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))
        }
        let emissionUpdatedPBR = try #require(emissivePBR.settingColor(boundColor, for: .emissionColor) as? PhysicallyBasedMaterial)
        #expect(emissionUpdatedPBR.emissiveColor.color.isApproximatelyEqual(to: boundColor))

        var unlit = UnlitMaterial()
        unlit.color.tint = baseColor
        let shadeUpdatedUnlit = try #require(unlit.settingColor(boundColor, for: .shadeColor) as? UnlitMaterial)
        let colorUpdatedUnlit = try #require(unlit.settingColor(boundColor, for: .color) as? UnlitMaterial)

        #expect(shadeUpdatedUnlit.color.tint.isApproximatelyEqual(to: baseColor))
        #expect(colorUpdatedUnlit.color.tint.isApproximatelyEqual(to: boundColor))
        #expect(unlit.currentColor(for: .shadeColor).isApproximatelyEqual(to: SIMD4<Float>(1, 1, 1, 1)))
    }

#if os(visionOS)
    /// visionOS has no `CustomMaterial`, so MToon always resolves to the
    /// Unlit / PBR conversion even when the loader is asked for it.
    @Test
    func testVisionOSUsesFallbackMaterialWhenMToonIsRequested() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let material = try loader.material(withMaterialIndex: 0)

        #expect(loader.shaders.contains { $0 is MToonShader })
        #expect(material is UnlitMaterial || material is PhysicallyBasedMaterial)
    }
#endif
}

private extension VRMColor {
    func isApproximatelyEqual(to other: VRMColor, tolerance: Float = 0.0001) -> Bool {
        simd.isApproximatelyEqual(to: other.simd, tolerance: tolerance)
    }
}
#endif
