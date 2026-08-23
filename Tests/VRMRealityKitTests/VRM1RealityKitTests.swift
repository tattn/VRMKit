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

        let direction = MToonMaterialParameters.defaultLightDirection
        #expect(customMaterial.custom.value.isApproximatelyEqual(to: SIMD4<Float>(direction, 0)))
    }

    @Test
    func testVRM1MToonRenderingCanBeDisabled() throws {
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

        let disabledEntity = try disabledLoader.loadEntity()
        #expect(!TestSupport.hasCustomMaterial(in: disabledEntity))
        #expect(!TestSupport.hasMToonParameters(in: disabledEntity))
    }

    @Test
    func testMToonParameterTextureRowsMatchMetalConstant() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try vrmLoader.loadEntity()
        let parameters = try firstMToonParameters(in: vrmEntity)
        let texture = try parameters.textureResource()
        let shader = TestSupport.mtoonShaderSource

        #expect(MToonMaterialParameters.baseParameterRowCount == 17)
        #expect(MToonMaterialParameters.samplerRowCount == MToonTextureSlot.allCases.count)
        #expect(MToonMaterialParameters.textureRowCount == 26)
        #expect(parameters.samplers.count == MToonMaterialParameters.samplerRowCount)
        #expect(texture.width == MToonMaterialParameters.textureRowCount)
        #expect(texture.height == 1)

        // The shader's row constants must match MToonParameterRow exactly:
        // extract them instead of restating the literals, so any reordering or
        // insertion on either side fails here.
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
        let vrmEntity = try loader.loadEntity()
        let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)

        #expect(parameters.normalParameters.x.isApproximatelyEqual(to: 0.35))
    }

    @Test
    func testMToonSkipsWorkThatCannotContribute() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san material 0 ("hair") has an outlineWidthMultiplyTexture; 1
        // ("huku_bake") does not, so the flag must differ between them.
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        #expect(try mtoonParameters(in: entity, materialIndex: 0).outlineParams.w == 1)
        #expect(try mtoonParameters(in: entity, materialIndex: 1).outlineParams.w == 0)
    }

    @Test
    func testMToonMaskTextureSlotsUseRawSemantic() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let textureIndex = 0
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "raw-mask-textures") { mtoon in
            mtoon["shadingShiftTexture"] = ["index": textureIndex]
            mtoon["outlineWidthMultiplyTexture"] = ["index": textureIndex]
            mtoon["uvAnimationMaskTexture"] = ["index": textureIndex]
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
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try vrmLoader.loadEntity()
        var parameters = try firstMToonParameters(in: vrmEntity)
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
        let vrmEntity = try vrmLoader.loadEntity()
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
    func testTransparentOutlinePreservesBaseTextureAlpha() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "transparent-outline") { material in
            material["alphaMode"] = "BLEND"
            var pbr = material["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 0.5]
            material["pbrMetallicRoughness"] = pbr
        }

        let loader = try VRMEntityLoader(withData: modified)
        let vrmEntity = try loader.loadEntity()
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
            guard var pbr = material["pbrMetallicRoughness"] as? [String: Any],
                  var baseTexture = pbr["baseColorTexture"] as? [String: Any],
                  var extensions = material["extensions"] as? [String: Any],
                  var mtoon = extensions["VRMC_materials_mtoon"] as? [String: Any],
                  var shadeTexture = mtoon["shadeMultiplyTexture"] as? [String: Any] else {
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
            pbr["baseColorTexture"] = baseTexture
            material["pbrMetallicRoughness"] = pbr

            shadeTexture["extensions"] = [
                "KHR_texture_transform": [
                    "offset": [0.9, 0.8],
                    "scale": [0.4, 0.3]
                ]
            ]
            mtoon["shadeMultiplyTexture"] = shadeTexture
            extensions["VRMC_materials_mtoon"] = mtoon
            material["extensions"] = extensions
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
            guard var shadeTexture = mtoon["shadeMultiplyTexture"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon texture fixture data")
            }
            shadeTexture["extensions"] = [
                "KHR_texture_transform": [
                    "offset": [0.9, 0.8],
                    "scale": [0.4, 0.3]
                ]
            ]
            mtoon["shadeMultiplyTexture"] = shadeTexture
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
    func testNormalMappedMeshesCarryACompleteTangentBasis() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()

        var checkedParts = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let mesh = modelEntity.components[ModelComponent.self]?.mesh else { continue }
            for part in mesh.contents.models.flatMap(\.parts) {
                guard let tangents = part.tangents?.elements, !tangents.isEmpty else { continue }
                // MToon.metal falls back to the geometry normal unless both
                // buffers are present and non-degenerate, and RealityKit derives
                // neither buffer from the other.
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
    /// the mesh stores UVs with v up. A basis generated from the stored UVs would
    /// have the opposite handedness to the one a TANGENT accessor supplies, so
    /// the generated bitangent has to follow glTF +v.
    @Test
    func testGeneratedBitangentsFollowTheGLTFUVOrientation() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()

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
    /// short NORMAL accessor has to fail the load rather than be indexed per
    /// vertex while the tangent basis is built.
    @Test
    func testVertexAttributeShorterThanPositionFailsTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "short NORMAL") { json in
            guard var accessors = json["accessors"] as? [[String: Any]],
                  let meshes = json["meshes"] as? [[String: Any]],
                  let primitives = meshes.first?["primitives"] as? [[String: Any]],
                  let attributes = primitives.first?["attributes"] as? [String: Any],
                  let normalIndex = attributes["NORMAL"] as? Int,
                  accessors.indices.contains(normalIndex),
                  let count = accessors[normalIndex]["count"] as? Int, count > 1 else {
                throw VRMError.dataInconsistent("Missing Seed-san NORMAL accessor")
            }
            accessors[normalIndex]["count"] = count - 1
            json["accessors"] = accessors
        }

        let loader = try VRMEntityLoader(withData: data)
        #expect(throws: VRMError.self) {
            try loader.loadEntity()
        }
    }

    /// glTF defines `JOINTS_n` as unsigned integer indices. A signed or floating
    /// point component type is a malformed file, and converting one to `UInt32`
    /// traps for a negative or out-of-range value, so the load has to fail.
    @Test
    func testSignedJointIndicesFailTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "signed JOINTS_0") { json in
            guard var accessors = json["accessors"] as? [[String: Any]],
                  let meshes = json["meshes"] as? [[String: Any]],
                  let primitives = meshes.first?["primitives"] as? [[String: Any]],
                  let attributes = primitives.first?["attributes"] as? [String: Any],
                  let jointsIndex = attributes["JOINTS_0"] as? Int,
                  accessors.indices.contains(jointsIndex),
                  // The signed counterpart of the same width, so the accessor
                  // still fits its buffer view and the component type is what
                  // fails the load.
                  let signed = [5121: 5120, 5123: 5122][accessors[jointsIndex]["componentType"] as? Int ?? 0] else {
                throw VRMError.dataInconsistent("Missing Seed-san JOINTS_0 accessor")
            }
            accessors[jointsIndex]["componentType"] = signed
            json["accessors"] = accessors
        }

        let loader = try VRMEntityLoader(withData: data)
        #expect(throws: VRMError.self) {
            try loader.loadEntity()
        }
    }

    /// glTF defines `inverseBindMatrices` as one matrix per skin joint. An
    /// accessor covering fewer of them is a broken file, and quietly padding it
    /// with identities would bind those joints to the wrong rest pose.
    @Test
    func testShortInverseBindMatricesFailTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "short inverseBindMatrices") { json in
            guard var accessors = json["accessors"] as? [[String: Any]],
                  let skins = json["skins"] as? [[String: Any]],
                  let matricesIndex = skins.first?["inverseBindMatrices"] as? Int,
                  accessors.indices.contains(matricesIndex),
                  let count = accessors[matricesIndex]["count"] as? Int, count > 1 else {
                throw VRMError.dataInconsistent("Missing Seed-san inverseBindMatrices accessor")
            }
            accessors[matricesIndex]["count"] = count - 1
            json["accessors"] = accessors
        }

        let loader = try VRMEntityLoader(withData: data)
        #expect {
            try loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "inverseBindMatrices")
        }
    }

    /// A TRIANGLES primitive holds a multiple of three indices. Trimming the
    /// remainder away would load a file whose triangle list is not the one it
    /// describes, so the load fails instead.
    @Test
    func testTriangleIndexCountThatIsNotAMultipleOfThreeFailsTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "partial triangle") { json in
            guard var accessors = json["accessors"] as? [[String: Any]],
                  let meshes = json["meshes"] as? [[String: Any]],
                  let primitives = meshes.first?["primitives"] as? [[String: Any]],
                  let indicesIndex = primitives.first?["indices"] as? Int,
                  accessors.indices.contains(indicesIndex),
                  let count = accessors[indicesIndex]["count"] as? Int, count > 3 else {
                throw VRMError.dataInconsistent("Missing Seed-san indices accessor")
            }
            accessors[indicesIndex]["count"] = count - 1
            json["accessors"] = accessors
        }

        let loader = try VRMEntityLoader(withData: data)
        #expect {
            try loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "TRIANGLES")
        }
    }

    /// glTF stores `WEIGHTS_n` as floats or as normalized integers. An
    /// unnormalized integer accessor holds raw counts, not the 0...1 weights the
    /// joint influences are built from.
    @Test
    func testUnnormalizedIntegerJointWeightsFailTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "unnormalized WEIGHTS_0") { json in
            guard var accessors = json["accessors"] as? [[String: Any]],
                  let meshes = json["meshes"] as? [[String: Any]],
                  let primitives = meshes.first?["primitives"] as? [[String: Any]],
                  let attributes = primitives.first?["attributes"] as? [String: Any],
                  let weightsIndex = attributes["WEIGHTS_0"] as? Int,
                  accessors.indices.contains(weightsIndex) else {
                throw VRMError.dataInconsistent("Missing Seed-san WEIGHTS_0 accessor")
            }
            // Narrower than the float components the fixture ships, so the
            // accessor still fits its buffer view and the missing `normalized`
            // flag is what fails the load.
            accessors[weightsIndex]["componentType"] = 5121
            accessors[weightsIndex]["normalized"] = false
            json["accessors"] = accessors
        }

        let loader = try VRMEntityLoader(withData: data)
        #expect {
            try loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "WEIGHTS_0")
        }
    }

    /// The light direction is carried in `custom.value` and the light color in a
    /// parameter row, so updating one must not drop the other.
    @Test
    func testMToonLightColorUpdateKeepsTheCustomLightDirection() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmLoader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try vrmLoader.loadEntity()

        vrmEntity.setMToonLightDirection(SIMD3<Float>(0, 0, -2))
        vrmEntity.setMToonLightColor(SIMD3<Float>(0.8, 0.7, 0.6))

        let parameters = try firstMToonParameters(in: vrmEntity)
        #expect(parameters.lightColor.isApproximatelyEqual(to: SIMD4<Float>(0.8, 0.7, 0.6, 1)))
        #expect(parameters.lightDirection.isApproximatelyEqual(to: SIMD3<Float>(0, 0, -1)))
#if !os(visionOS)
        let material = try firstCustomMaterial(in: vrmEntity)
        #expect(material.custom.value.isApproximatelyEqual(to: SIMD4<Float>(0, 0, -1, 0)))
        #expect(material.custom.texture != nil)
#endif
    }

    private func isDataInconsistent(_ error: any Error, containing fragment: String) -> Bool {
        guard case VRMError.dataInconsistent(let message) = error else { return false }
        return message.contains(fragment)
    }

    /// VRM 0.x keeps its normal map in Unity's `_BumpMap`, which the migration
    /// surfaces on the MToon descriptor and not on the glTF material. A
    /// primitive without a TANGENT accessor still needs a generated basis for
    /// it, or MToon.metal falls back to the geometry normal and the map does
    /// nothing.
    @Test
    func testVRM0BumpMapGeneratesATangentBasisWithoutTANGENT() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let materialIndex = 0
        let data = try TestSupport.modifiedAliciaSolidData(name: "VRM0 _BumpMap without TANGENT") { json in
            guard var extensions = json["extensions"] as? [String: Any],
                  var vrm = extensions["VRM"] as? [String: Any],
                  var properties = vrm["materialProperties"] as? [[String: Any]],
                  properties.indices.contains(materialIndex),
                  var textures = properties[materialIndex]["textureProperties"] as? [String: Any],
                  let mainTexture = textures["_MainTex"],
                  var meshes = json["meshes"] as? [[String: Any]] else {
                throw VRMError.dataInconsistent("Missing AliciaSolid material properties")
            }
            // The fixture ships unlit materials with a TANGENT accessor, which
            // is the opposite of what this exercises.
            properties[materialIndex]["shader"] = "VRM/MToon"
            textures["_BumpMap"] = mainTexture
            properties[materialIndex]["textureProperties"] = textures
            vrm["materialProperties"] = properties
            extensions["VRM"] = vrm
            json["extensions"] = extensions

            for meshIndex in meshes.indices {
                guard var primitives = meshes[meshIndex]["primitives"] as? [[String: Any]] else { continue }
                for primitiveIndex in primitives.indices {
                    guard primitives[primitiveIndex]["material"] as? Int == materialIndex,
                          var attributes = primitives[primitiveIndex]["attributes"] as? [String: Any] else { continue }
                    attributes.removeValue(forKey: "TANGENT")
                    primitives[primitiveIndex]["attributes"] = attributes
                }
                meshes[meshIndex]["primitives"] = primitives
            }
            json["meshes"] = meshes
        }

        let loader = try VRMEntityLoader(withData: data, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()

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
    func testSetMToonLightAndAmbientColorUpdateParameterRows() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try vrmLoader.loadEntity()
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
    func testMToonTextureTransformBindUpdatesParameterTexture() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try vrmLoader.loadEntity()

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
    func testExpressionTextureTransformsAccumulateAndResetIndependently() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let loader = try VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()

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
    func testExpressionMaterialColorsAccumulateAndResetIndependently() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "accumulated-material-colors") { json in
            guard var materials = json["materials"] as? [[String: Any]],
                  materials.indices.contains(0),
                  var pbr = materials[0]["pbrMetallicRoughness"] as? [String: Any],
                  var extensions = json["extensions"] as? [String: Any],
                  var vrm = extensions["VRMC_vrm"] as? [String: Any],
                  var expressions = vrm["expressions"] as? [String: Any],
                  var preset = expressions["preset"] as? [String: Any],
                  var happy = preset["happy"] as? [String: Any],
                  var angry = preset["angry"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san expression fixture data")
            }
            pbr["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
            materials[0]["pbrMetallicRoughness"] = pbr
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
            preset["happy"] = happy
            preset["angry"] = angry
            expressions["preset"] = preset
            vrm["expressions"] = expressions
            extensions["VRMC_vrm"] = vrm
            json["extensions"] = extensions
            json["materials"] = materials
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()
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
    func testBlockingExpressionOverrideSuppressesBlinkAndLookAtWeights() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's `relaxed` declares overrideBlink / overrideLookAt = block.
        let vrmEntity = try VRMEntityLoader(withData: TestSupport.seedSanData,
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
    func testBlendingExpressionOverrideScalesBlinkWeights() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's `happy` declares overrideBlink = blend, but is binary; a
        // non-binary variant makes the partial blend observable.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "non-binary-happy") { preset in
            guard var happy = preset["happy"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san happy expression")
            }
            happy["isBinary"] = false
            preset["happy"] = happy
        }
        let vrmEntity = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.happy): 0.25])

        let blinkWeight = try #require(morphWeight(in: vrmEntity, targetIndex: 1))
        #expect(blinkWeight.isApproximatelyEqual(to: 0.75))
    }

    /// Alicia's `Joy` and `Fun` groups both bind face target 38. VRM 0.x blend
    /// shape groups load as expressions, so two meeting on one morph target
    /// compose the way VRM 1.0 expressions do: their contributions add up
    /// rather than overwrite.
    @Test
    func testVRM0BlendShapeGroupsSharingAMorphTargetAccumulate() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()

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
    func testSimultaneousBlendOverridesAccumulateBeforeSaturating() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Two non-binary expressions that each blend-override blink. VRM sums
        // their weights and saturates, so 0.5 + 0.5 fully suppresses blink;
        // composing the factors multiplicatively would leave 0.25 behind.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "two-blend-overrides") { preset in
            for name in ["happy", "sad"] {
                guard var expression = preset[name] as? [String: Any] else {
                    throw VRMError.dataInconsistent("Missing Seed-san \(name) expression")
                }
                expression["isBinary"] = false
                expression["overrideBlink"] = "blend"
                preset[name] = expression
            }
        }
        let vrmEntity = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.happy): 0.5])
        #expect(try #require(morphWeight(in: vrmEntity, targetIndex: 1)).isApproximatelyEqual(to: 0.5))

        vrmEntity.setExpression(value: 0.5, for: .preset(.sad))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 0)

        // Past saturation the weight stays at 0 rather than going negative.
        vrmEntity.setExpressions([.preset(.happy): 1, .preset(.sad): 1])
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 0)
    }

    @Test
    func testOverriddenBinaryExpressionIsSuppressedEntirely() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // A binary expression has no partial state, so *any* override effect
        // must zero it rather than scale it.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "binary-blink") { preset in
            guard var blink = preset["blink"] as? [String: Any],
                  var happy = preset["happy"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san blink/happy expressions")
            }
            blink["isBinary"] = true
            happy["isBinary"] = false
            happy["overrideBlink"] = "blend"
            preset["blink"] = blink
            preset["happy"] = happy
        }
        let vrmEntity = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpression(value: 1, for: .preset(.blink))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 1)

        // A 0.25 blend would leave 0.75 on a non-binary expression.
        vrmEntity.setExpression(value: 0.25, for: .preset(.happy))
        #expect(morphWeight(in: vrmEntity, targetIndex: 1) == 0)
    }

    @Test
    func testExpressionDoesNotOverrideItsOwnKind() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // "Like overrideBlink for blink, settings for the same kind are treated
        // as invalid": blink must not suppress itself or its own group.
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "self-overriding-blink") { preset in
            guard var blink = preset["blink"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san blink expression")
            }
            blink["overrideBlink"] = "block"
            preset["blink"] = blink
        }
        let vrmEntity = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()

        vrmEntity.setExpressions([.preset(.blink): 1, .preset(.blinkLeft): 1])

        #expect(morphWeight(in: vrmEntity, targetIndex: 2) == 1)
    }

// These tests observe MToon runtime state, which visionOS never produces:
// there is no `CustomMaterial`, so MToon falls back to Unlit / PBR materials.
#if !os(visionOS)
    @Test
    func testBinaryExpressionIsOnlyActiveAboveHalf() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // `angry` is binary and carries a textureTransformBind on material 11.
        let vrmEntity = try VRMEntityLoader(withData: TestSupport.seedSanData,
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
    func testSetExpressionsAppliesEveryWeightAtOnce() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try VRMEntityLoader(withData: TestSupport.seedSanData,
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
    func testMToonSamplerKeepsMagAndMinFiltersIndependent() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // glTF magFilter and minFilter are independent, so a LINEAR magFilter
        // must stay linear next to a NEAREST minFilter.
        // Material 0's base color texture uses sampler 0.
        let modified = try TestSupport.modifiedSeedSanData(name: "mixed-filter-sampler") { json in
            guard var samplers = json["samplers"] as? [[String: Any]], !samplers.isEmpty else {
                throw VRMError.dataInconsistent("Missing Seed-san sampler fixture data")
            }
            samplers[0]["magFilter"] = 9729                 // LINEAR
            samplers[0]["minFilter"] = 9728                 // NEAREST
            samplers[0]["wrapS"] = 33071                    // CLAMP_TO_EDGE
            samplers[0]["wrapT"] = 33648                    // MIRRORED_REPEAT
            json["samplers"] = samplers
        }

        let vrmEntity = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()
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
                guard var samplers = json["samplers"] as? [[String: Any]], !samplers.isEmpty else {
                    throw VRMError.dataInconsistent("Missing Seed-san sampler fixture data")
                }
                samplers[0]["minFilter"] = entry.raw
                json["samplers"] = samplers
            }
            let vrmEntity = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()
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
                material["alphaMode"] = alphaMode
                guard var extensions = material["extensions"] as? [String: Any],
                      var mtoon = extensions["VRMC_materials_mtoon"] as? [String: Any] else {
                    throw VRMError.dataInconsistent("Missing Seed-san MToon extension")
                }
                mtoon["transparentWithZWrite"] = transparentWithZWrite
                extensions["VRMC_materials_mtoon"] = mtoon
                material["extensions"] = extensions
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
    func testUpdateAppliesSpringBonePosesWithoutAFrameOfLag() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try VRMEntityLoader(withData: TestSupport.seedSanData,
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

    @Test
    func testScenesSharingNodesLoadIndependentEntityGraphs() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // A second scene referencing the same root nodes. Entity instances
        // cannot be shared between scenes, so each load must build its own.
        let modified = try TestSupport.modifiedSeedSanData(name: "duplicated-scene") { json in
            guard var scenes = json["scenes"] as? [[String: Any]], let first = scenes.first else {
                throw VRMError.dataInconsistent("Missing Seed-san scene fixture data")
            }
            scenes.append(first)
            json["scenes"] = scenes
        }
        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)

        let firstScene = try loader.loadEntity(withSceneIndex: 0)
        let secondScene = try loader.loadEntity(withSceneIndex: 1)

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
        let reloaded = try loader.loadEntity(withSceneIndex: 0)
        #expect(reloaded !== firstScene)
        #expect(reloaded.hasRuntimeBindings)
        #expect(Set(TestSupport.modelEntities(in: reloaded).map(ObjectIdentifier.init))
            .isDisjoint(with: firstModels))
        #expect(morphWeight(in: reloaded, targetIndex: 33) == 0)
        #expect(morphWeight(in: firstScene, targetIndex: 33) == 1)
    }

    @Test
    func testVRM1FirstPersonAutoHidesHeadDescendants() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try vrmLoader.loadEntity()
        let annotatedEntity = try vrmLoader.node(withNodeIndex: 0)

        #expect(annotatedEntity.isEnabled == true)
        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(annotatedEntity.isEnabled == false)
        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(annotatedEntity.isEnabled == true)
    }

#if !os(visionOS)
    @Test
    func testUpdateDoesNotMutateMToonMaterialsPerFrame() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try vrmLoader.loadEntity()
        let initialValue = try firstCustomMaterial(in: vrmEntity).custom.value

        vrmEntity.update(deltaTime: 0.25)
        vrmEntity.update(deltaTime: 0.5)

        // UV animation time comes from params.uniforms().time() on the GPU;
        // update() must not touch MToon materials at all.
        let afterUpdateValue = try firstCustomMaterial(in: vrmEntity).custom.value
        #expect(afterUpdateValue == initialValue)
    }

    @Test
    func testSetMToonLightDirectionUpdatesRegisteredMaterials() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let vrmLoader = try VRMEntityLoader(withData: seedSan)
        let vrmEntity = try vrmLoader.loadEntity()

        // The direction is normalized before it reaches the parameter rows.
        vrmEntity.setMToonLightDirection(SIMD3<Float>(0, 0, -2))

        // Every MToon material is rebound, not just the first one found, and
        // each keeps the parameter texture the shader samples. Only xyz carries
        // the direction; w is the outline pass's bounds budget, left as it is.
        var checkedMaterials = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let model = modelEntity.components[ModelComponent.self] else { continue }
            let isOutlinePass = modelEntity.components.has(GLTFMaterialPassComponent.self)
            for material in model.materials.compactMap({ $0 as? CustomMaterial }) {
                let value = material.custom.value
                #expect(SIMD3<Float>(value.x, value.y, value.z).isApproximatelyEqual(to: SIMD3<Float>(0, 0, -1)))
                #expect(isOutlinePass ? value.w > 0 : value.w == 0)
                #expect(material.custom.texture != nil)
                checkedMaterials += 1
            }
        }
        #expect(checkedMaterials > 0)
    }

    @Test
    func testMalformedMaterialColorBindDoesNotFailModelLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "malformed-color-bind") { json in
            guard var extensions = json["extensions"] as? [String: Any],
                  var vrm = extensions["VRMC_vrm"] as? [String: Any],
                  var expressions = vrm["expressions"] as? [String: Any],
                  var preset = expressions["preset"] as? [String: Any],
                  var happy = preset["happy"] as? [String: Any] else {
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
            preset["happy"] = happy
            expressions["preset"] = preset
            vrm["expressions"] = expressions
            extensions["VRMC_vrm"] = vrm
            json["extensions"] = extensions
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()

        // The invalid bind is skipped while the valid one keeps working.
        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        let parameters = try mtoonParameters(in: vrmEntity, materialIndex: 0)
        #expect(parameters.baseColor.x.isApproximatelyEqual(to: 0.5))
    }

    /// A malformed MToon extension is a rendering limitation, not a broken file:
    /// the material falls back to Unlit / PBR and the model still loads.
    @Test
    func testMToonExtensionWithAnInvalidTextureFallsBackInsteadOfFailingTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "mtoon-texture-out-of-range") { mtoon in
            mtoon["shadeMultiplyTexture"] = ["index": 9999]
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()

        // The state goes with the material, so no expression bind keeps writing
        // parameter rows no shader reads.
        #expect(vrmEntity.mtoonParameters(forMaterialIndex: 0) == nil)
        #expect(!TestSupport.modelEntities(in: vrmEntity).isEmpty)
    }

    /// One unbuildable material must cost that primitive its material, not the
    /// whole model.
    @Test
    func testMaterialThatCannotBeBuiltFallsBackToTheDefaultMaterial() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "base-texture-out-of-range") { material in
            // Without the MToon extension the material takes the Unlit / PBR
            // path, where an out-of-range base color texture throws.
            material["extensions"] = [String: Any]()
            material["pbrMetallicRoughness"] = ["baseColorTexture": ["index": 9999]]
        }

        let loader = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try loader.loadEntity()

        #expect(TestSupport.materialIndexes(in: vrmEntity).contains(0))
        #expect(!TestSupport.modelEntities(in: vrmEntity).isEmpty)
    }

    @Test
    func testFallbackMaterialsDoNotCarryMToonRuntimeState() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let loader = try VRMEntityLoader(withData: seedSan, shaders: [])
        let vrmEntity = try loader.loadEntity()

        // With MToon disabled, no entity carries MToon runtime state, and
        // expression color binds resolve through the fallback material path.
        #expect(!TestSupport.hasMToonParameters(in: vrmEntity))
        let fallbackColor = try vrmEntity.currentMaterialColor(withMaterialIndex: 0, type: .color, loader: loader)
        let fallbackMaterial = try loader.material(withMaterialIndex: 0)
        #expect(fallbackColor.isApproximatelyEqual(to: fallbackMaterial.currentColor(for: .color)))
    }

    @Test
    func testVRM1MToonOutlineEntitiesFollowTheOutlineOption() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let seedSan = TestSupport.seedSanData
        let outlineEntity = try VRMEntityLoader(withData: seedSan).loadEntity()
        #expect(hasOutlineEntities(in: outlineEntity))

        // Outlines are the inverted hull only; disabling them must not take the
        // MToon surface shader with them.
        let noOutlineEntity = try VRMEntityLoader(withData: seedSan, shaders: TestSupport.noOutlineShaders).loadEntity()
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
            guard var samplers = json["samplers"] as? [[String: Any]],
                  samplers.indices.contains(7) else {
                throw VRMError.dataInconsistent("Missing Seed-san sampler fixture data")
            }
            samplers[7]["magFilter"] = 9728
            samplers[7]["minFilter"] = 9728
            samplers[7]["wrapS"] = 33071
            samplers[7]["wrapT"] = 33071
            json["samplers"] = samplers
        }
    }
}

private extension VRMColor {
    func isApproximatelyEqual(to other: VRMColor, tolerance: Float = 0.0001) -> Bool {
        simd.isApproximatelyEqual(to: other.simd, tolerance: tolerance)
    }
}

#endif
