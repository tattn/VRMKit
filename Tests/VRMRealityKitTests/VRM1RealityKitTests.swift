#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

@Suite
@MainActor
struct VRM1RealityKitTests {

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
        // carries the outline budget.
        #expect(customMaterial.custom.value.isApproximatelyEqual(to: SIMD4<Float>(0, 0, 0, 0)))
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
    func testMToonParameterTextureRowsMatchMetalConstant() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try await vrmLoader.loadEntity()
        let parameters = try firstMToonParameters(in: vrmEntity)
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
    func testMToonNormalScaleIsPassedToShaderParameters() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "normal-scale") { material in
            material["normalTexture"] = ["index": 0, "scale": 0.35]
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()
        let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)

        #expect(parameters.normalParameters.x.isApproximatelyEqual(to: 0.35))
    }

    @Test
    func testMToonSkipsWorkThatCannotContribute() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san material 0 ("hair") has an outlineWidthMultiplyTexture; 1
        // ("huku_bake") does not, so the flag must differ between them.
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        #expect(try mtoonParameters(in: entity, materialIndex: 0).outlineParams.w == 1)
        #expect(try mtoonParameters(in: entity, materialIndex: 1).outlineParams.w == 0)
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
    func testMToonEmissiveFlagFactorAndEmissionColorBind() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try await vrmLoader.loadEntity()
        var parameters = try firstMToonParameters(in: vrmEntity)
        let boundColor = SIMD4<Float>(0.25, 0.5, 0.75, 0.2)

        #expect(parameters.extraFlags.z == 0 || parameters.extraFlags.z == 1)
        #expect(parameters.color(for: .emissionColor).isApproximatelyEqual(to: parameters.emissiveFactor))
        parameters.setColor(boundColor, for: .emissionColor)
        #expect(parameters.emissiveFactor.isApproximatelyEqual(to: SIMD4<Float>(0.25, 0.5, 0.75, 1)))
        #expect(parameters.color(for: .emissionColor).isApproximatelyEqual(to: parameters.emissiveFactor))
    }

    @Test
    func testMToonShadeMultiplyTextureFallsBackToWhite() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try seedSanDataWithNonDefaultEyeSampler()
        let vrmLoader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await vrmLoader.loadEntity()
        let eyeTransparentParameters = try mtoonParameters(in: vrmEntity, materialIndex: 4)

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

    @Test
    func testNormalMappedMeshesCarryACompleteTangentBasis() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        var checkedParts = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let mesh = modelEntity.components[ModelComponent.self]?.mesh else { continue }
            for part in mesh.contents.models.flatMap(\.parts) {
                guard let tangents = part.tangents?.elements, !tangents.isEmpty else { continue }
                // MToon.metal falls back to the geometry normal unless both
                // buffers are present and non-degenerate.
                let bitangents = try #require(part.bitangents?.elements)
                #expect(tangents.count == part.positions.count)
                #expect(bitangents.count == tangents.count)
                #expect(tangents.allSatisfy { simd_length_squared($0) > 0.5 })
                #expect(bitangents.allSatisfy { simd_length_squared($0) > 0.5 })
                checkedParts += 1
            }
        }
        // Seed-san's normal-mapped materials have no glTF TANGENT attribute, so
        // reaching this count also proves the generated basis is used.
        #expect(checkedParts > 0)
    }

    /// MToon samples the normal map in glTF UV space, where v points down, while
    /// the mesh stores UVs with v up, so the generated bitangent has to follow
    /// glTF +v to match what a TANGENT accessor supplies.
    @Test
    func testGeneratedBitangentsFollowTheGLTFUVOrientation() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        var checkedTriangles = 0
        var agreeingTriangles = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let mesh = modelEntity.components[ModelComponent.self]?.mesh else { continue }
            for part in mesh.contents.models.flatMap(\.parts) {
                guard let bitangents = part.bitangents?.elements, !bitangents.isEmpty,
                      let texcoords = part.textureCoordinates?.elements,
                      let indices = part.triangleIndices?.elements else { continue }
                let positions = part.positions.elements
                for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
                    let i0 = Int(indices[triangle])
                    let i1 = Int(indices[triangle + 1])
                    let i2 = Int(indices[triangle + 2])
                    let deltaUV1 = texcoords[i1] - texcoords[i0]
                    let deltaUV2 = texcoords[i2] - texcoords[i0]
                    // The stored v runs the other way, so the glTF-space
                    // determinant is the stored one negated.
                    let determinant = deltaUV2.x * deltaUV1.y - deltaUV1.x * deltaUV2.y
                    guard abs(determinant) > 1e-9 else { continue }
                    let edge1 = positions[i1] - positions[i0]
                    let edge2 = positions[i2] - positions[i0]
                    let expected = (edge2 * deltaUV1.x - edge1 * deltaUV2.x) / determinant
                    guard simd_length_squared(expected) > 1e-10 else { continue }
                    checkedTriangles += 1
                    if simd_dot(simd_normalize(expected), bitangents[i0]) > 0 {
                        agreeingTriangles += 1
                    }
                }
            }
        }
        #expect(checkedTriangles > 0)
        // Vertices shared by triangles with opposing UV gradients average out, so
        // a few legitimately disagree; a flipped basis inverts the ratio entirely.
        #expect(Float(agreeingTriangles) > Float(checkedTriangles) * 0.9)
    }

    /// glTF requires every vertex attribute to match POSITION in length, so a
    /// short NORMAL accessor has to fail the load.
    @Test
    func testVertexAttributeShorterThanPositionFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "short NORMAL") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let attributes = primitives.first?.object("attributes"),
                  let normalIndex = attributes.int("NORMAL"),
                  accessors.indices.contains(normalIndex),
                  let count = accessors[normalIndex].int("count"), count > 1 else {
                throw VRMError.dataInconsistent("Missing Seed-san NORMAL accessor")
            }
            accessors[normalIndex]["count"] = .int(count - 1)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect(throws: VRMError.self) {
            try await loader.loadEntity()
        }
    }

    /// glTF defines `JOINTS_n` as unsigned integer indices, and converting a
    /// signed one to `UInt32` would trap, so the load has to fail.
    @Test
    func testSignedJointIndicesFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "signed JOINTS_0") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let attributes = primitives.first?.object("attributes"),
                  let jointsIndex = attributes.int("JOINTS_0"),
                  accessors.indices.contains(jointsIndex),
                  // The signed counterpart of the same width, so the component
                  // type is what fails the load.
                  let signed = [5121: 5120, 5123: 5122][accessors[jointsIndex].int("componentType") ?? 0] else {
                throw VRMError.dataInconsistent("Missing Seed-san JOINTS_0 accessor")
            }
            accessors[jointsIndex]["componentType"] = .int(signed)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect(throws: VRMError.self) {
            try await loader.loadEntity()
        }
    }

    /// glTF defines `inverseBindMatrices` as one matrix per skin joint, and
    /// padding a short one with identities would bind the wrong rest pose.
    @Test
    func testShortInverseBindMatricesFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "short inverseBindMatrices") { json in
            var accessors = json.objects("accessors")
            guard let matricesIndex = json.objects("skins").first?.int("inverseBindMatrices"),
                  accessors.indices.contains(matricesIndex),
                  let count = accessors[matricesIndex].int("count"), count > 1 else {
                throw VRMError.dataInconsistent("Missing Seed-san inverseBindMatrices accessor")
            }
            accessors[matricesIndex]["count"] = .int(count - 1)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect {
            try await loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "inverseBindMatrices")
        }
    }

    /// A TRIANGLES primitive holds a multiple of three indices, and trimming the
    /// remainder would draw a triangle list the file does not describe.
    @Test
    func testTriangleIndexCountThatIsNotAMultipleOfThreeFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "partial triangle") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let indicesIndex = primitives.first?.int("indices"),
                  accessors.indices.contains(indicesIndex),
                  let count = accessors[indicesIndex].int("count"), count > 3 else {
                throw VRMError.dataInconsistent("Missing Seed-san indices accessor")
            }
            accessors[indicesIndex]["count"] = .int(count - 1)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect {
            try await loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "TRIANGLES")
        }
    }

    /// glTF stores `WEIGHTS_n` as floats or as normalized integers. An
    /// unnormalized integer accessor holds raw counts, not the 0...1 weights the
    /// joint influences are built from.
    @Test
    func testUnnormalizedIntegerJointWeightsFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "unnormalized WEIGHTS_0") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let attributes = primitives.first?.object("attributes"),
                  let weightsIndex = attributes.int("WEIGHTS_0"),
                  accessors.indices.contains(weightsIndex) else {
                throw VRMError.dataInconsistent("Missing Seed-san WEIGHTS_0 accessor")
            }
            // Narrower than the float components the fixture ships, so the
            // missing `normalized` flag is what fails the load.
            accessors[weightsIndex]["componentType"] = 5121
            accessors[weightsIndex]["normalized"] = false
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect {
            try await loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "WEIGHTS_0")
        }
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
#if !os(visionOS)
        let material = try firstCustomMaterial(in: vrmEntity)
        #expect(material.custom.texture != nil)
#endif
    }

    private func isDataInconsistent(_ error: any Error, containing fragment: String) -> Bool {
        guard let error = error as? VRMError, error.kind == .dataInconsistent else { return false }
        return error.message.contains(fragment)
    }

    /// VRM 0.x keeps its normal map in Unity's `_BumpMap`, which the migration
    /// surfaces on the MToon descriptor rather than on the glTF material, so a
    /// primitive without TANGENT still needs a generated basis for it.
    @Test
    func testVRM0BumpMapGeneratesATangentBasisWithoutTANGENT() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let materialIndex = 0
        let data = try TestSupport.modifiedAliciaSolidData(name: "VRM0 _BumpMap without TANGENT") { json in
            guard var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRM") else {
                throw VRMError.dataInconsistent("Missing AliciaSolid material properties")
            }
            var properties = vrm.objects("materialProperties")
            guard properties.indices.contains(materialIndex),
                  var textures = properties[materialIndex].object("textureProperties"),
                  let mainTexture = textures["_MainTex"] else {
                throw VRMError.dataInconsistent("Missing AliciaSolid material properties")
            }
            var meshes = json.objects("meshes")
            // The fixture ships unlit materials with a TANGENT accessor, which
            // is the opposite of what this exercises.
            properties[materialIndex]["shader"] = "VRM/MToon"
            textures["_BumpMap"] = mainTexture
            properties[materialIndex]["textureProperties"] = .object(textures)
            vrm["materialProperties"] = .objects(properties)
            extensions["VRM"] = .object(vrm)
            json["extensions"] = .object(extensions)

            for meshIndex in meshes.indices {
                var primitives = meshes[meshIndex].objects("primitives")
                guard !primitives.isEmpty else { continue }
                for primitiveIndex in primitives.indices {
                    guard primitives[primitiveIndex].int("material") == materialIndex,
                          var attributes = primitives[primitiveIndex].object("attributes") else { continue }
                    attributes.removeValue(forKey: "TANGENT")
                    primitives[primitiveIndex]["attributes"] = .object(attributes)
                }
                meshes[meshIndex]["primitives"] = .objects(primitives)
            }
            json["meshes"] = .objects(meshes)
        }

        let loader = try VRMEntityLoader(withData: data, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        var checkedParts = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity)
        where modelEntity.components[GLTFMaterialIndexComponent.self]?.materialIndex == materialIndex {
            guard let mesh = modelEntity.components[ModelComponent.self]?.mesh else { continue }
            for part in mesh.contents.models.flatMap(\.parts) {
                let tangents = try #require(part.tangents?.elements)
                let bitangents = try #require(part.bitangents?.elements)
                #expect(tangents.count == part.positions.count)
                #expect(bitangents.count == tangents.count)
                #expect(tangents.contains { simd_length_squared($0) > 0.5 })
                checkedParts += 1
            }
        }
        #expect(checkedParts > 0)
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

        let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.25, 0)))
        #expect(parameters.uvTransformRotation.isApproximatelyEqual(to: SIMD4<Float>(1, 0, 0, 0)))
        // The parameter rows are the only UV-transform source for MToon; the
        // material-level transform stays identity so the shader applies it once.
        let material = try customMaterial(in: vrmEntity, materialIndex: 11)
        #expect(material.textureCoordinateTransform.offset == SIMD2<Float>(0, 0))
        #expect(material.textureCoordinateTransform.scale == SIMD2<Float>(1, 1))
    }

    @Test
    func testExpressionTextureTransformsAccumulateAndResetIndependently() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let loader = try VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        vrmEntity.setExpression(value: 1, for: .preset(.angry))
        var parameters = try mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.75, 0)))
        #expect(vrmEntity.expression(for: .preset(.happy)) == 1)
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)

        vrmEntity.setExpression(value: 0, for: .preset(.happy))
        parameters = try mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.5, 0)))
        #expect(vrmEntity.expression(for: .preset(.happy)) == 0)
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)
    }

    @Test
    func testExpressionMaterialColorsAccumulateAndResetIndependently() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "accumulated-material-colors") { json in
            var materials = json.objects("materials")
            guard materials.indices.contains(0),
                  var pbr = materials[0].object("pbrMetallicRoughness"),
                  var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRMC_vrm"),
                  var expressions = vrm.object("expressions"),
                  var preset = expressions.object("preset"),
                  var happy = preset.object("happy"),
                  var angry = preset.object("angry") else {
                throw VRMError.dataInconsistent("Missing Seed-san expression fixture data")
            }
            pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
            materials[0]["pbrMetallicRoughness"] = .object(pbr)
            happy["materialColorBinds"] = [[
                "material": 0,
                "type": "color",
                "targetValue": [0.8, 1.0, 1.0, 1.0]
            ]]
            angry["materialColorBinds"] = [[
                "material": 0,
                "type": "color",
                "targetValue": [1.0, 0.6, 1.0, 1.0]
            ]]
            preset["happy"] = .object(happy)
            preset["angry"] = .object(angry)
            expressions["preset"] = .object(preset)
            vrm["expressions"] = .object(expressions)
            extensions["VRMC_vrm"] = .object(vrm)
            json["extensions"] = .object(extensions)
            json["materials"] = .objects(materials)
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()
        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        vrmEntity.setExpression(value: 1, for: .preset(.angry))
        var parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.isApproximatelyEqual(to: SIMD4<Float>(0.8, 0.6, 1, 1)))

        vrmEntity.setExpression(value: 0, for: .preset(.happy))
        parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.isApproximatelyEqual(to: SIMD4<Float>(1, 0.6, 1, 1)))
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

    @Test
    func testBlockingExpressionOverrideSuppressesBlinkAndLookAtWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's `relaxed` declares overrideBlink / overrideLookAt = block.
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.blink))
        vrmEntity.setExpression(value: 1, for: .preset(.lookUp))
        vrmEntity.setExpression(value: 1, for: .preset(.aa))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 1)
        #expect(morphWeight(in: vrmEntity, targetIndex: 39) == 1)
        #expect(morphWeight(in: vrmEntity, targetIndex: 25) == 1)

        vrmEntity.setExpression(value: 1, for: .preset(.relaxed))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 0)
        #expect(morphWeight(in: vrmEntity, targetIndex: 39) == 0)
        // overrideMouth is `none`, so mouth expressions keep their weight.
        #expect(morphWeight(in: vrmEntity, targetIndex: 25) == 1)
        // The input weights themselves are untouched by the override.
        #expect(vrmEntity.expression(for: .preset(.blink)) == 1)

        vrmEntity.setExpression(value: 0, for: .preset(.relaxed))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 1)
        #expect(morphWeight(in: vrmEntity, targetIndex: 39) == 1)
    }

    @Test
    func testBlendingExpressionOverrideScalesBlinkWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's `happy` declares overrideBlink = blend, but is binary; a
        // non-binary variant makes the partial blend observable.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "non-binary-happy") { preset in
            guard var happy = preset.object("happy") else {
                throw VRMError.dataInconsistent("Missing Seed-san happy expression")
            }
            happy["isBinary"] = false
            preset["happy"] = .object(happy)
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.happy): 0.25])

        let blinkWeight = try #require(morphWeight(in: vrmEntity, targetIndex: 1))
        #expect(blinkWeight.isApproximatelyEqual(to: 0.75))
    }

    /// Alicia's `Joy` and `Fun` groups both bind face target 38, and VRM 0.x blend
    /// shape groups load as expressions, so their contributions add up.
    @Test
    func testVRM0BlendShapeGroupsSharingAMorphTargetAccumulate() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()

        vrmEntity.setExpression(value: 0.25, for: .preset(.happy))
        #expect(try #require(morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.25))

        vrmEntity.setExpression(value: 0.5, for: .preset(.relaxed))
        #expect(try #require(morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.75))
        // Joy's own targets keep the weight Joy gave them.
        #expect(try #require(morphWeight(in: vrmEntity, targetIndex: 14)).isApproximatelyEqual(to: 0.25))

        // Releasing one group takes back its share alone.
        vrmEntity.setExpression(value: 0, for: .preset(.happy))
        #expect(try #require(morphWeight(in: vrmEntity, targetIndex: 38)).isApproximatelyEqual(to: 0.5))
        #expect(try #require(morphWeight(in: vrmEntity, targetIndex: 14)).isApproximatelyEqual(to: 0))
    }

    @Test
    func testSimultaneousBlendOverridesAccumulateBeforeSaturating() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Two non-binary expressions that each blend-override blink. VRM sums
        // their weights and saturates, so 0.5 + 0.5 fully suppresses blink.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "two-blend-overrides") { preset in
            for name in ["happy", "sad"] {
                guard var expression = preset.object(name) else {
                    throw VRMError.dataInconsistent("Missing Seed-san \(name) expression")
                }
                expression["isBinary"] = false
                expression["overrideBlink"] = "blend"
                preset[name] = .object(expression)
            }
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.happy): 0.5])
        #expect(try #require(morphWeight(in: vrmEntity, targetIndex: 1)).isApproximatelyEqual(to: 0.5))

        vrmEntity.setExpression(value: 0.5, for: .preset(.sad))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 0)

        // Past saturation the weight stays at 0 rather than going negative.
        vrmEntity.setExpressions([.preset(.happy): 1, .preset(.sad): 1])
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 0)
    }

    @Test
    func testOverriddenBinaryExpressionIsSuppressedEntirely() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // A binary expression has no partial state, so *any* override effect
        // must zero it rather than scale it.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "binary-blink") { preset in
            guard var blink = preset.object("blink"),
                  var happy = preset.object("happy") else {
                throw VRMError.dataInconsistent("Missing Seed-san blink/happy expressions")
            }
            blink["isBinary"] = true
            happy["isBinary"] = false
            happy["overrideBlink"] = "blend"
            preset["blink"] = .object(blink)
            preset["happy"] = .object(happy)
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.blink))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 1)

        // A 0.25 blend would leave 0.75 on a non-binary expression.
        vrmEntity.setExpression(value: 0.25, for: .preset(.happy))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 0)
    }

    @Test
    func testExpressionDoesNotOverrideItsOwnKind() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // "Like overrideBlink for blink, settings for the same kind are treated
        // as invalid": blink must not suppress itself or its own group.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "self-overriding-blink") { preset in
            guard var blink = preset.object("blink") else {
                throw VRMError.dataInconsistent("Missing Seed-san blink expression")
            }
            blink["overrideBlink"] = "block"
            preset["blink"] = .object(blink)
        }
        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.blinkLeft): 1])

        #expect(morphWeight(in: vrmEntity, targetIndex: 2) == 1)
    }

// These tests observe MToon runtime state, which visionOS never produces:
// there is no `CustomMaterial`, so MToon falls back to Unlit / PBR materials.
#if !os(visionOS)
    @Test
    func testBinaryExpressionIsOnlyActiveAboveHalf() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // `angry` is binary and carries a textureTransformBind on material 11.
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpression(value: 0.5, for: .preset(.angry))
        var parameters = try mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0, 0)))
        #expect(vrmEntity.expression(for: .preset(.angry)) == 0)

        vrmEntity.setExpression(value: 0.51, for: .preset(.angry))
        parameters = try mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.5, 0)))
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)
    }

    @Test
    func testSetExpressionsAppliesEveryWeightAtOnce() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.happy): 1, .preset(.angry): 1])

        // Same accumulated result as setting each expression on its own.
        let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 11)
        #expect(parameters.uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0.75, 0)))
        #expect(vrmEntity.expression(for: .preset(.happy)) == 1)
        #expect(vrmEntity.expression(for: .preset(.angry)) == 1)

        vrmEntity.setExpressions([.preset(.happy): 0, .preset(.angry): 0])
        #expect(try mtoonParameters(in: vrmEntity, materialIndex: 11)
            .uvTransform.isApproximatelyEqual(to: SIMD4<Float>(1, 1, 0, 0)))
    }

    @Test
    func testMToonSamplerKeepsMagAndMinFiltersIndependent() async throws {
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

        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()
        let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)

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
    func testEveryGLTFMinFilterMapsToADistinctSampler() async throws {
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
            let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()
            let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)
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
#endif

    @Test
    func testUpdateAppliesSpringBonePosesWithoutAFrameOfLag() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: []).loadEntity()

        // Rotating a parent bone drags the spring chains, so spring bones write
        // new joint transforms during update().
        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        var checkedJoints = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let model = modelEntity.components[ModelComponent.self],
                  let skeleton = model.mesh.contents.skeletons.first,
                  let pose = modelEntity.components[SkeletalPosesComponent.self]?.poses.default,
                  pose.jointTransforms.count == skeleton.joints.count else {
                continue
            }
            let jointEntities = skeleton.joints.map { vrmEntity.findEntity(named: $0.name) }
            let jointWorlds = jointEntities.map { $0?.transformMatrix(relativeTo: nil) }
            let modelWorldInverse = modelEntity.transformMatrix(relativeTo: nil).inverse

            for index in skeleton.joints.indices {
                guard let jointWorld = jointWorlds[index] else { continue }
                let expected: simd_float4x4
                if let parentIndex = skeleton.joints[index].parentIndex,
                   let parentWorld = jointWorlds[parentIndex] {
                    expected = parentWorld.inverse * jointWorld
                } else {
                    expected = modelWorldInverse * jointWorld
                }
                // The pose must describe the hierarchy as it stands after
                // update(), not as it stood before the spring bones ran.
                #expect(pose.jointTransforms[index].matrix.isApproximatelyEqual(to: expected, tolerance: 0.0005))
                checkedJoints += 1
            }
        }
        #expect(checkedJoints > 0)
    }

    /// `VRMC_springBone` pairs the joints of a spring consecutively, so the
    /// last of them is only the tail the one before it swings towards.
    @Test
    func testTheLastJointOfASpringIsOnlyItsTail() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
        guard case .v1(let vrm1) = vrmEntity.vrm else {
            Issue.record("Seed-san is a VRM 1.0 fixture")
            return
        }
        let springs = try #require(vrm1.springBone?.springs)
        let swinging = Set(springs.flatMap { $0.joints.dropLast().map(\.node) })
        // A tail that another spring swings is one this cannot answer for.
        let tailsOnly = Set(springs.compactMap { $0.joints.last?.node }).subtracting(swinging)
        #expect(!tailsOnly.isEmpty)
        let tails = tailsOnly.compactMap { vrmEntity.entity(forNodeAt: $0) }
        let heads = swinging.compactMap { vrmEntity.entity(forNodeAt: $0) }
        let tailRotations = tails.map(\.transform.rotation)
        let headRotations = heads.map(\.transform.rotation)

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(tails.map(\.transform.rotation) == tailRotations)
        // Not an expectation a model standing still would meet anyway.
        #expect(heads.map(\.transform.rotation) != headRotations)
    }

    /// A spring of one joint has no pair in it, so there is nothing to swing.
    @Test
    func testASpringOfOneJointSwingsNothing() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        var jointNode = 0
        let data = try TestSupport.modifiedSeedSanData(name: "one joint spring") { json in
            var extensions = json.object("extensions") ?? [:]
            var springBone = extensions.object("VRMC_springBone") ?? [:]
            let springs = springBone.objects("springs")
            let joints = springs.first?.objects("joints") ?? []
            guard let node = joints.first?.int("node") else {
                throw VRMError.dataInconsistent("Missing Seed-san spring bone fixture data")
            }
            jointNode = node
            springBone["springs"] = [["joints": [["node": .int(node)]]]]
            extensions["VRMC_springBone"] = .object(springBone)
            json["extensions"] = .object(extensions)
        }
        let vrmEntity = try await VRMEntityLoader(withData: data, shaders: []).loadEntity()
        let joint = try #require(vrmEntity.entity(forNodeAt: jointNode))
        let rotation = joint.transform.rotation

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(joint.transform.rotation == rotation)
    }

    @Test
    func testScenesSharingNodesLoadIndependentEntityGraphs() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // A second scene referencing the same root nodes. Entity instances
        // cannot be shared between scenes, so each load must build its own.
        let modified = try TestSupport.modifiedSeedSanData(name: "duplicated-scene") { json in
            var scenes = json.objects("scenes")
            guard let first = scenes.first else {
                throw VRMError.dataInconsistent("Missing Seed-san scene fixture data")
            }
            scenes.append(first)
            json["scenes"] = .objects(scenes)
        }
        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)

        let firstScene = try await loader.loadEntity(withSceneIndex: 0)
        let secondScene = try await loader.loadEntity(withSceneIndex: 1)

        #expect(firstScene !== secondScene)
        // Neither scene may have had its nodes stolen by the other: both keep a
        // full hierarchy, and no entity appears in both.
        #expect(!firstScene.children.isEmpty)
        #expect(firstScene.children.count == secondScene.children.count)
        let firstModels = Set(TestSupport.modelEntities(in: firstScene).map(ObjectIdentifier.init))
        let secondModels = Set(TestSupport.modelEntities(in: secondScene).map(ObjectIdentifier.init))
        #expect(!firstModels.isEmpty)
        #expect(firstModels.count == secondModels.count)
        #expect(firstModels.isDisjoint(with: secondModels))

        // Each scene drives its own runtime state.
        firstScene.setExpression(value: 1, for: .preset(.happy))
        #expect(morphWeight(in: firstScene, targetIndex: 33) == 1)
        #expect(morphWeight(in: secondScene, targetIndex: 33) == 0)

        // Loading a scene again builds another independent entity, so one loader
        // can hand out several animatable copies of the same scene.
        let reloaded = try await loader.loadEntity(withSceneIndex: 0)
        #expect(reloaded !== firstScene)
        #expect(reloaded.hasRuntimeBindings)
        #expect(Set(TestSupport.modelEntities(in: reloaded).map(ObjectIdentifier.init))
            .isDisjoint(with: firstModels))
        #expect(morphWeight(in: reloaded, targetIndex: 33) == 0)
        #expect(morphWeight(in: firstScene, targetIndex: 33) == 1)
    }

    /// A `thirdPersonOnly` mesh goes in first person. What goes is the mesh,
    /// not the node drawing it, so the nodes hanging off that one keep drawing.
    @Test
    func testVRM1ThirdPersonOnlyMeshIsHiddenInFirstPerson() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmLoader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try await vrmLoader.loadEntity()
        let node = try #require(vrmEntity.entity(forNodeAt: 0))
        let mesh = try #require(node.children.first)

        #expect(mesh.isEnabled == true)
        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(mesh.isEnabled == false)
        #expect(node.isEnabled == true)
        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(mesh.isEnabled == true)
    }

    /// glTF lets two nodes draw one mesh, and VRM 1.0 annotates the node rather
    /// than the mesh, so one of the two may go in first person while the other
    /// stays.
    @Test
    func testVRM1AnnotatesEachNodeDrawingAMeshOnItsOwn() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Node 0 draws mesh 0 as `thirdPersonOnly`; the copy draws it as `both`.
        let data = try Self.seedSanSharingMeshZero(copyAnnotatedAs: "both")
        let vrmLoader = try VRMEntityLoader(withData: data)
        let vrmEntity = try await vrmLoader.loadEntity()
        let annotated = try #require(vrmEntity.entity(forNodeAt: 0)?.children.first)
        let copy = try #require(vrmEntity.entity(forNodeAt: Self.seedSanMeshCopyNodeIndex)?.children.first)

        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(annotated.isEnabled == false)
        #expect(copy.isEnabled == true)

        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(annotated.isEnabled == true)
        #expect(copy.isEnabled == true)
    }

    /// The `auto` cut is made as a mesh is built, so a mesh one node draws
    /// `auto` and another draws whole is built twice rather than cut for both.
    @Test
    func testVRM1CutsAMeshOnlyForTheNodesAnnotatedAuto() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Node 0 draws mesh 0 as `auto`, so the head's triangles go; the copy
        // draws it as `both`, so it keeps them.
        let data = try Self.seedSanSharingMeshZero(copyAnnotatedAs: "both") { annotations in
            annotations.map { annotation in
                var annotation = annotation
                if annotation.int("node") == 0 { annotation["type"] = .string("auto") }
                return annotation
            }
        }
        let vrmLoader = try VRMEntityLoader(withData: data, shaders: [])
        let vrmEntity = try await vrmLoader.loadEntity()
        let annotated = try #require(vrmEntity.entity(forNodeAt: 0)?.children.first)
        let copy = try #require(vrmEntity.entity(forNodeAt: Self.seedSanMeshCopyNodeIndex)?.children.first)

        let cutPrimitives = TestSupport.firstPersonCuts(in: annotated)
        #expect(!cutPrimitives.isEmpty)
        #expect(TestSupport.firstPersonCuts(in: copy).isEmpty)
    }

    /// The node index the fixture rewrite below gives its copy of node 0.
    private static let seedSanMeshCopyNodeIndex = 147

    /// Seed-san with a second node drawing node 0's mesh through node 0's skin,
    /// annotated `copyAnnotatedAs`. `modifyAnnotations` rewrites the annotations
    /// the fixture already carries.
    private static func seedSanSharingMeshZero(
        copyAnnotatedAs type: String,
        modifyAnnotations: ([[String: JSONValue]]) -> [[String: JSONValue]] = { $0 }
    ) throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "one mesh drawn by two nodes") { json in
            var nodes = json.objects("nodes")
            guard nodes.count == seedSanMeshCopyNodeIndex,
                  let mesh = nodes.first?.int("mesh"), let skin = nodes.first?.int("skin") else {
                throw VRMError.dataInconsistent("Unexpected Seed-san node layout")
            }
            nodes.append(["name": .string("hair_copy"), "mesh": .int(mesh), "skin": .int(skin)])
            json["nodes"] = .objects(nodes)

            var scenes = json.objects("scenes")
            let roots = (scenes.first?["nodes"]?.arrayValue ?? []) + [.int(seedSanMeshCopyNodeIndex)]
            scenes[0]["nodes"] = .array(roots)
            json["scenes"] = .objects(scenes)

            guard var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRMC_vrm"),
                  var firstPerson = vrm.object("firstPerson") else {
                throw VRMError.dataInconsistent("Missing Seed-san firstPerson")
            }
            let annotations = modifyAnnotations(firstPerson.objects("meshAnnotations"))
            firstPerson["meshAnnotations"] = .objects(
                annotations + [["node": .int(seedSanMeshCopyNodeIndex), "type": .string(type)]]
            )
            vrm["firstPerson"] = .object(firstPerson)
            extensions["VRMC_vrm"] = .object(vrm)
            json["extensions"] = .object(extensions)
        }
    }

    /// An `auto` mesh keeps the triangles no head bone draws, and a primitive
    /// the head draws whole goes with it.
    @Test
    func testFirstPersonAutoDrawsAMeshWithoutTheHeadsTriangles() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Alicia annotates every mesh `Auto`, hers being split head from body.
        let vrmLoader = try VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data, shaders: [])
        let vrmEntity = try await vrmLoader.loadEntity()
        let cut = TestSupport.firstPersonCuts(in: vrmEntity)
        let trimmed = try #require(cut.first { $0.component.firstPersonMesh != nil })
        let dropped = try #require(cut.first { $0.component.firstPersonMesh == nil })

        // The trimmed primitive loses triangles without losing all of them.
        let whole = TestSupport.triangleIndexCount(of: trimmed.component.thirdPersonMesh)
        let headless = TestSupport.triangleIndexCount(of: try #require(trimmed.component.firstPersonMesh))
        #expect(headless > 0)
        #expect(headless < whole)

        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(TestSupport.drawnTriangleIndexCount(of: trimmed.entity) == headless)
        #expect(dropped.entity.isEnabled == false)

        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(TestSupport.drawnTriangleIndexCount(of: trimmed.entity) == whole)
        #expect(dropped.entity.isEnabled == true)
    }

#if !os(visionOS)
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

        // The materials still hold the shared parameter texture, with only the
        // outline budget in custom.value.
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let model = modelEntity.components[ModelComponent.self] else { continue }
            let isOutlinePass = modelEntity.components.has(GLTFMaterialPassComponent.self)
            for material in model.materials.compactMap({ $0 as? CustomMaterial }) {
                let value = material.custom.value
                #expect(SIMD3<Float>(value.x, value.y, value.z) == .zero)
                #expect(isOutlinePass ? value.w > 0 : value.w == 0)
                #expect(material.custom.texture != nil)
            }
        }
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
        let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)
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
#endif

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

    /// The blend-shape weight currently applied for a glTF morph target index,
    /// read back from the model entities the way RealityKit renders it.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func morphWeight(in root: Entity, targetIndex: Int) -> Float? {
        let targetName = "blendShape_\(targetIndex)"
        for modelEntity in TestSupport.modelEntities(in: root) {
            let weights = modelEntity.blendWeights
            let names = modelEntity.blendWeightNames
            for setIndex in names.indices where setIndex < weights.count {
                guard let nameIndex = names[setIndex].firstIndex(of: targetName),
                      nameIndex < weights[setIndex].count else { continue }
                return weights[setIndex][nameIndex]
            }
        }
        return nil
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func mtoonParameters(in vrmEntity: VRMEntity, materialIndex: Int) throws -> MToonMaterialParameters {
        guard let parameters = vrmEntity.mtoonParameters(forMaterialIndex: materialIndex) else {
            throw VRMError.dataInconsistent("Expected MToon parameters for material \(materialIndex)")
        }
        return parameters
    }

#if !os(visionOS)
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func customMaterial(in root: Entity,
                                materialIndex: Int,
                                faceCulling: CustomMaterial.FaceCulling? = nil) throws -> CustomMaterial {
        for modelEntity in TestSupport.modelEntities(in: root) {
            guard modelEntity.components[GLTFMaterialIndexComponent.self]?.materialIndex == materialIndex,
                  let model = modelEntity.components[ModelComponent.self],
                  let material = model.materials.first as? CustomMaterial else {
                continue
            }
            if let faceCulling, material.faceCulling != faceCulling {
                continue
            }
            return material
        }
        throw VRMError.dataInconsistent("Expected CustomMaterial for material \(materialIndex)")
    }
#endif

#if !os(visionOS)

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
#endif

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
}

private extension VRMColor {
    func isApproximatelyEqual(to other: VRMColor, tolerance: Float = 0.0001) -> Bool {
        simd.isApproximatelyEqual(to: other.simd, tolerance: tolerance)
    }
}

#endif
