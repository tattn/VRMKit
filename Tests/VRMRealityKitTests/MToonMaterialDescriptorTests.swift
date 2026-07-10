import Foundation
import Testing
@testable import VRMKit
@testable import VRMKitRuntime

@Suite
struct MToonMaterialDescriptorTests {
    @Test
    func testVRM0DefaultValuesMigrateToMToon10Domain() throws {
        let descriptor = try #require(MToonMaterialDescriptor(material: material(),
                                                              materialProperty: vrm0MaterialProperty()))

        #expect(descriptor.shadingToonyFactor.isApproximatelyEqual(to: 0.95))
        #expect(descriptor.shadingShiftFactor.isApproximatelyEqual(to: -0.05))
        #expect(descriptor.giEqualizationFactor.isApproximatelyEqual(to: 0.9))
        #expect(descriptor.rimLightingMixFactor == 0)
    }

    @Test
    func testVRM0MigratesOutlineWidthAndUvRotationUnits() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"""
                {
                  "_OutlineWidthMode": 1,
                  "_OutlineWidth": 3.5,
                  "_UvAnimRotation": 0.25
                }
                """#)
        ))

        #expect(descriptor.outlineWidthMode == .worldCoordinates)
        #expect(descriptor.outlineWidthFactor.isApproximatelyEqual(to: 0.035))
        #expect(descriptor.uvAnimationRotationSpeedFactor.isApproximatelyEqual(to: 0.5 * Float.pi))
    }

    @Test
    func testVRM0RenderQueueOffsetMigratesTransparentQueues() throws {
        let transparentNoZWrite = try descriptor(renderQueue: 2994,
                                                 keywordMap: #"{"_ALPHABLEND_ON": true}"#,
                                                 tagMap: #"{"RenderType": "Transparent"}"#)
        #expect(transparentNoZWrite.renderQueueOffsetNumber == -6)

        let transparentNoZWriteClamped = try descriptor(renderQueue: 2980,
                                                        keywordMap: #"{"_ALPHABLEND_ON": true}"#,
                                                        tagMap: #"{"RenderType": "Transparent"}"#)
        #expect(transparentNoZWriteClamped.renderQueueOffsetNumber == -9)

        let transparentZWrite = try descriptor(renderQueue: 2508,
                                               keywordMap: #"{"_ALPHABLEND_ON": true, "_ZWRITE_ON": true}"#,
                                               tagMap: #"{"RenderType": "Transparent"}"#)
        #expect(transparentZWrite.renderQueueOffsetNumber == 7)

        let transparentZWriteClamped = try descriptor(renderQueue: 2520,
                                                      keywordMap: #"{"_ALPHABLEND_ON": true, "_ZWRITE_ON": true}"#,
                                                      tagMap: #"{"RenderType": "Transparent"}"#)
        #expect(transparentZWriteClamped.renderQueueOffsetNumber == 9)

        let shaderDefaultQueue = try descriptor(renderQueue: 0,
                                                keywordMap: #"{"_ALPHABLEND_ON": true}"#,
                                                tagMap: #"{"RenderType": "Transparent"}"#)
        #expect(shaderDefaultQueue.renderQueueOffsetNumber == 0)
    }

    @Test
    func testVRM0EmissiveFieldsUseEmissionProperties() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(textures: #"{"_EmissionMap": 3}"#,
                                                   vectors: #"{"_EmissionColor": [0.2, 0.3, 0.4, 1.0]}"#)
        ))

        #expect(descriptor.emissiveFactor.isApproximatelyEqual(to: SIMD3<Float>(0.2, 0.3, 0.4)))
        #expect(descriptor.emissiveTexture?.index == 3)
        #expect(descriptor.emissiveTexture?.texCoord == 0)
    }

    @Test
    func testVRM0ShadeTextureTakesPriorityOverMainTexture() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(textures: #"{"_MainTex": 2, "_ShadeTexture": 4}"#)
        ))

        #expect(descriptor.baseColorTexture?.index == 2)
        #expect(descriptor.shadeMultiplyTexture?.index == 4)
        #expect(descriptor.shadeMultiplyTexture?.texCoord == 0)
    }

    @Test
    func testVRM0ShadeTextureFallsBackToMainTexture() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(textures: #"{"_MainTex": 2}"#)
        ))

        #expect(descriptor.baseColorTexture?.index == 2)
        #expect(descriptor.shadeMultiplyTexture?.index == 2)
        #expect(descriptor.shadeMultiplyTexture?.texCoord == 0)
    }

    @Test
    func testVRM1MissingShadeTextureRemainsNil() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(#"""
                {
                  "pbrMetallicRoughness": {
                    "baseColorTexture": { "index": 2, "texCoord": 1 }
                  },
                  "extensions": {
                    "VRMC_materials_mtoon": {
                      "specVersion": "1.0"
                    }
                  }
                }
                """#),
            materialProperty: nil
        ))

        #expect(descriptor.baseColorTexture?.index == 2)
        #expect(descriptor.shadeMultiplyTexture == nil)
    }

    @Test
    func testVRM1MToon10Defaults() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: vrm1Material(),
            materialProperty: nil
        ))

        #expect(descriptor.shadeColorFactor == SIMD4<Float>(0, 0, 0, 1))
        #expect(descriptor.parametricRimFresnelPowerFactor == 5)
    }

    @Test
    func testVRM1EmissiveFieldsAndMatcapDefaultUseGltfMaterial() throws {
        let gltfMaterial = try material(#"""
            {
              "emissiveFactor": [0.6, 0.7, 0.8],
              "emissiveTexture": { "index": 5, "texCoord": 1 },
              "extensions": {
                "VRMC_materials_mtoon": {
                  "specVersion": "1.0"
                }
              }
            }
            """#)
        let descriptor = try #require(MToonMaterialDescriptor(material: gltfMaterial, materialProperty: nil))

        #expect(descriptor.emissiveFactor.isApproximatelyEqual(to: SIMD3<Float>(0.6, 0.7, 0.8)))
        #expect(descriptor.emissiveTexture?.index == 5)
        #expect(descriptor.emissiveTexture?.texCoord == 1)
        #expect(descriptor.matcapFactor.isApproximatelyEqual(to: SIMD3<Float>(1, 1, 1)))
    }

    private func descriptor(renderQueue: Int,
                            keywordMap: String,
                            tagMap: String) throws -> MToonMaterialDescriptor {
        return try #require(MToonMaterialDescriptor(
            material: material(#"{"alphaMode": "OPAQUE"}"#),
            materialProperty: vrm0MaterialProperty(renderQueue: renderQueue,
                                                   keywordMap: keywordMap,
                                                   tagMap: tagMap)
        ))
    }

    private func material(_ json: String = "{}") throws -> GLTF.Material {
        return try JSONDecoder().decode(GLTF.Material.self, from: Data(json.utf8))
    }

    private func vrm1Material() throws -> GLTF.Material {
        return try material(#"""
            {
              "extensions": {
                "VRMC_materials_mtoon": {
                  "specVersion": "1.0"
                }
              }
            }
            """#)
    }

    private func vrm0MaterialProperty(renderQueue: Int = 0,
                                      floats: String = "{}",
                                      keywordMap: String = "{}",
                                      tagMap: String = "{}",
                                      textures: String = "{}",
                                      vectors: String = "{}") throws -> VRM0.MaterialProperty {
        let json = #"""
            {
              "name": "MToon",
              "shader": "VRM/MToon",
              "renderQueue": \#(renderQueue),
              "floatProperties": \#(floats),
              "keywordMap": \#(keywordMap),
              "tagMap": \#(tagMap),
              "textureProperties": \#(textures),
              "vectorProperties": \#(vectors)
            }
            """#
        return try JSONDecoder().decode(VRM0.MaterialProperty.self, from: Data(json.utf8))
    }
}

private extension Float {
    func isApproximatelyEqual(to other: Float, tolerance: Float = 0.0001) -> Bool {
        return abs(self - other) < tolerance
    }
}

private extension SIMD3 where Scalar == Float {
    func isApproximatelyEqual(to other: SIMD3<Float>, tolerance: Float = 0.0001) -> Bool {
        return abs(x - other.x) < tolerance &&
            abs(y - other.y) < tolerance &&
            abs(z - other.z) < tolerance
    }
}
