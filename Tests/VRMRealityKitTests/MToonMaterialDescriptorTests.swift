import Foundation
import Testing
import VRMTestSupport
@testable import VRMKit

@Suite
struct MToonMaterialDescriptorTests {
    /// JSON numbers reach the VRM extensions as untyped `JSONValue`s, and glTF
    /// indices have to survive that intact: `Float` rounds `16_777_217` to its
    /// neighbour and `Int32.max` past its own range.
    @Test
    func testIndexCoercionAcceptsOnlyExactNonNegativeInt32Values() {
        #expect(JSONValue.int(0).indexValue == 0)
        #expect(JSONValue.int(7).indexValue == 7)
        #expect(JSONValue.int(16_777_217).indexValue == 16_777_217)
        #expect(JSONValue.int(Int(Int32.max)).indexValue == Int(Int32.max))
        #expect(JSONValue.int(Int(Int32.max) + 1).indexValue == nil)
        #expect(JSONValue.int(-1).indexValue == nil)
        #expect(JSONValue.double(1.5).indexValue == nil)
        #expect(JSONValue.double(.nan).indexValue == nil)
        #expect(JSONValue.bool(true).indexValue == nil)
        #expect(JSONValue.string("3").indexValue == nil)
    }

    @Test
    func testVRM0DefaultValuesMigrateToMToon10Domain() throws {
        let descriptor = try #require(MToonMaterialDescriptor(material: material(),
                                                              materialProperty: vrm0MaterialProperty()))

        #expect(descriptor.shadingToonyFactor.isApproximatelyEqual(to: 0.95))
        #expect(descriptor.shadingShiftFactor.isApproximatelyEqual(to: -0.05))
        #expect(descriptor.giEqualizationFactor.isApproximatelyEqual(to: 0.9))
        // UniVRM migrates rim lighting mix destructively to 1.0.
        #expect(descriptor.rimLightingMixFactor == 1)
    }

    @Test
    func testVRM0RimLightingMixIsMigratedDestructivelyLikeUniVRM() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"{"_RimLightingMix": 0.3}"#)
        ))

        #expect(descriptor.rimLightingMixFactor == 1)
    }

    @Test
    func testVRM0LitShadeRimOutlineColorsAreConvertedToLinear() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(vectors: #"""
                {
                  "_Color": [0.5, 0.5, 0.5, 0.5],
                  "_ShadeColor": [0.5, 0.5, 0.5, 1.0],
                  "_RimColor": [0.5, 0.5, 0.5, 1.0],
                  "_OutlineColor": [0.5, 0.5, 0.5, 1.0],
                  "_EmissionColor": [0.5, 0.5, 0.5, 1.0]
                }
                """#)
        ))
        let linearHalf = SRGB.toLinear(0.5)

        #expect(linearHalf.isApproximatelyEqual(to: 0.21404114))
        #expect(descriptor.baseColorFactor.isApproximatelyEqual(to: SIMD4<Float>(linearHalf, linearHalf, linearHalf, 0.5)))
        #expect(descriptor.shadeColorFactor.isApproximatelyEqual(to: SIMD4<Float>(linearHalf, linearHalf, linearHalf, 1)))
        #expect(descriptor.parametricRimColorFactor.isApproximatelyEqual(to: SIMD4<Float>(linearHalf, linearHalf, linearHalf, 1)))
        #expect(descriptor.outlineColorFactor.isApproximatelyEqual(to: SIMD4<Float>(linearHalf, linearHalf, linearHalf, 1)))
        // Emission is already linear in VRM 0.x and must be passed through.
        #expect(descriptor.emissiveFactor.isApproximatelyEqual(to: SIMD3<Float>(0.5, 0.5, 0.5)))
    }

    @Test
    func testVRM0UVAnimationScrollYIsInverted() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"{"_UvAnimScrollX": 0.1, "_UvAnimScrollY": 0.25}"#)
        ))

        #expect(descriptor.uvAnimationScrollXSpeedFactor.isApproximatelyEqual(to: 0.1))
        #expect(descriptor.uvAnimationScrollYSpeedFactor.isApproximatelyEqual(to: -0.25))
    }

    @Test
    func testVRM0ScreenOutlineWidthIsHalved() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"{"_OutlineWidthMode": 2, "_OutlineWidth": 10}"#)
        ))

        #expect(descriptor.outlineWidthMode == .screenCoordinates)
        #expect(descriptor.outlineWidthFactor.isApproximatelyEqual(to: 10 * 0.01 * 0.5))
    }

    @Test
    func testVRM0FixedOutlineColorModeRendersUnlit() throws {
        let fixed = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"{"_OutlineColorMode": 0, "_OutlineLightingMix": 0.8}"#)
        ))
        let mixed = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"{"_OutlineColorMode": 1, "_OutlineLightingMix": 0.8}"#)
        ))

        #expect(fixed.outlineLightingMixFactor == 0)
        #expect(mixed.outlineLightingMixFactor.isApproximatelyEqual(to: 0.8))
    }

    @Test
    func testVRM0OutOfRangeAndBooleanNumbersFallBackToDefaults() throws {
        // `1e100` overflows `Float` and JSON booleans bridge to `NSNumber`:
        // neither is a usable value, and converting them to `Int` would trap.
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"""
                {
                  "_OutlineWidthMode": 1e100,
                  "_OutlineColorMode": 1e100,
                  "_OutlineLightingMix": 0.8,
                  "_ShadeToony": true
                }
                """#)
        ))

        #expect(descriptor.outlineWidthMode == .none)
        #expect(descriptor.outlineWidthFactor == 0)
        #expect(descriptor.outlineLightingMixFactor == 0)
        #expect(descriptor.shadingToonyFactor.isApproximatelyEqual(to: 0.95))
    }

    @Test
    func testVRM1OutOfRangeTextureTransformNumbersFallBackToDefaults() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(#"""
                {
                  "emissiveTexture": {
                    "index": 5,
                    "texCoord": 1,
                    "extensions": {
                      "KHR_texture_transform": { "texCoord": 1e100, "rotation": 1e100 }
                    }
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

        // The unusable override is ignored, so the texture info's own texCoord wins.
        #expect(descriptor.emissiveTexture?.texCoord == 1)
        #expect(descriptor.emissiveTexture?.transform?.rotation == 0)
    }

    @Test
    func testVRM0MainTextureTransformIsMigrated() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(textures: #"{"_MainTex": 2, "_ShadeTexture": 4}"#,
                                                   vectors: #"{"_MainTex": [0.1, 0.2, 0.5, 0.4]}"#)
        ))

        let transform = try #require(descriptor.baseColorTexture?.transform)
        #expect(transform.scale == SIMD2<Float>(0.5, 0.4))
        #expect(transform.offset.isApproximatelyEqual(to: SIMD2<Float>(0.1, 1 - 0.2 - 0.4)))
        #expect(transform.rotation == 0)
        // MToon 0.x applies the material's _MainTex ST to every texture.
        #expect(descriptor.shadeMultiplyTexture?.transform == transform)
    }

    @Test
    func testVRM0IdentityMainTextureTransformStaysNil() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(textures: #"{"_MainTex": 2}"#,
                                                   vectors: #"{"_MainTex": [0, 0, 1, 1]}"#)
        ))

        #expect(descriptor.baseColorTexture?.transform == nil)
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
    func testVRM0RenderQueueIsNotMigratedToAnOffset() throws {
        // renderQueueOffsetNumber is a relative order among a model's transparent
        // materials, so a per-material conversion of Unity's absolute renderQueue
        // would fabricate an ordering; VRM 0.x stays neutral.
        for renderQueue in [0, 2508, 2980, 2994, 3000, 3200] {
            let transparent = try descriptor(renderQueue: renderQueue,
                                             keywordMap: #"{"_ALPHABLEND_ON": true}"#,
                                             tagMap: #"{"RenderType": "Transparent"}"#)
            #expect(transparent.renderQueueOffsetNumber == 0)

            let zWrite = try descriptor(renderQueue: renderQueue,
                                        floats: #"{"_BlendMode": 3, "_ZWrite": 1}"#,
                                        keywordMap: #"{"_ALPHABLEND_ON": true}"#,
                                        tagMap: #"{"RenderType": "Transparent"}"#)
            #expect(zWrite.renderQueueOffsetNumber == 0)
            // The TransparentWithZWrite render mode still reaches the descriptor.
            #expect(zWrite.transparentWithZWrite)
        }
    }

    /// MToon 0.x carries its render mode in `_BlendMode`, not in a shader
    /// keyword, so only mode 3 migrates to transparentWithZWrite.
    @Test
    func testVRM0TransparentWithZWriteComesFromTheBlendMode() throws {
        let transparentTags = #"{"RenderType": "Transparent"}"#
        let blend = #"{"_ALPHABLEND_ON": true}"#

        for blendMode in [0, 1, 2] {
            let other = try descriptor(renderQueue: 3000,
                                       floats: #"{"_BlendMode": \#(blendMode), "_ZWrite": 1}"#,
                                       keywordMap: blend,
                                       tagMap: transparentTags)
            #expect(!other.transparentWithZWrite, "_BlendMode \(blendMode) is not TransparentWithZWrite")
        }

        // Without `_BlendMode`, `_ZWrite` is the only signal left, and it only
        // separates the transparent modes.
        let zWriteOnly = try descriptor(renderQueue: 3000,
                                        floats: #"{"_ZWrite": 1}"#,
                                        keywordMap: blend,
                                        tagMap: transparentTags)
        #expect(zWriteOnly.transparentWithZWrite)

        let opaqueZWrite = try descriptor(renderQueue: 2000,
                                          floats: #"{"_ZWrite": 1}"#,
                                          keywordMap: "{}",
                                          tagMap: #"{"RenderType": "Opaque"}"#)
        #expect(!opaqueZWrite.transparentWithZWrite)
    }

    @Test
    func testVRM0BaseColorFallsBackToLinearGltfFactor() throws {
        // _Color is a Unity sRGB color and needs converting; the glTF
        // baseColorFactor fallback is already a linear multiplier and must not
        // be converted a second time.
        let gltfMaterial = try material(#"""
            {"pbrMetallicRoughness": {"baseColorFactor": [0.5, 0.5, 0.5, 1.0]}}
            """#)
        let fallback = try #require(MToonMaterialDescriptor(material: gltfMaterial,
                                                            materialProperty: vrm0MaterialProperty()))
        #expect(fallback.baseColorFactor.isApproximatelyEqual(to: SIMD4<Float>(0.5, 0.5, 0.5, 1)))

        let unityColor = try #require(MToonMaterialDescriptor(
            material: gltfMaterial,
            materialProperty: vrm0MaterialProperty(vectors: #"{"_Color": [0.5, 0.5, 0.5, 1.0]}"#)
        ))
        #expect(unityColor.baseColorFactor.x < 0.5)
        #expect(unityColor.baseColorFactor.x.isApproximatelyEqual(to: SRGB.toLinear(0.5)))
        #expect(unityColor.baseColorFactor.w.isApproximatelyEqual(to: 1))
    }

    @Test
    func testUnsupportedMToonSpecVersionFallsBackToNonMToon() throws {
        // A future revision must not be reinterpreted with 1.0 semantics; the
        // renderer falls back to Unlit / PBR instead.
        for specVersion in ["1.0", "1.0-beta"] {
            let supported = try material(#"""
                {"extensions": {"VRMC_materials_mtoon": {"specVersion": "\#(specVersion)"}}}
                """#)
            #expect(MToonMaterialDescriptor(material: supported, materialProperty: nil) != nil,
                    "specVersion \(specVersion) should be supported")
        }
        for specVersion in ["2.0", "0.9", ""] {
            let unsupported = try material(#"""
                {"extensions": {"VRMC_materials_mtoon": {"specVersion": "\#(specVersion)"}}}
                """#)
            #expect(MToonMaterialDescriptor(material: unsupported, materialProperty: nil) == nil,
                    "specVersion \(specVersion) should not be treated as MToon 1.0")
        }
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

        // MToon 1.0 defaults the shade color to white, not to black.
        #expect(descriptor.shadeColorFactor == SIMD4<Float>(1, 1, 1, 1))
        #expect(descriptor.parametricRimFresnelPowerFactor == 5)
        #expect(descriptor.cullMode == .back)
        #expect(descriptor.normalScale == 1)
    }

    @Test
    func testVRM0CullModePreservesFrontBackAndDisabledValues() throws {
        let expected: [(Float, MToonMaterialDescriptor.CullMode)] = [
            (0, .none),
            (1, .front),
            (2, .back)
        ]

        for (value, cullMode) in expected {
            let descriptor = try #require(MToonMaterialDescriptor(
                material: material(),
                materialProperty: vrm0MaterialProperty(floats: #"{"_CullMode": \#(value)}"#)
            ))
            #expect(descriptor.cullMode == cullMode)
        }
    }

    @Test
    func testVRM0InvalidCullModeUsesMaterialFallback() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"{"_CullMode": 1.5}"#)
        ))

        #expect(descriptor.cullMode == .back)
    }

    @Test
    func testVRM1DoubleSidedDisablesCulling() throws {
        let descriptor = try #require(MToonMaterialDescriptor(
            material: material(#"{"doubleSided": true, "extensions": {"VRMC_materials_mtoon": {"specVersion": "1.0"}}}"#),
            materialProperty: nil
        ))

        #expect(descriptor.cullMode == .none)
    }

    @Test
    func testNormalScaleUsesVRM0AndVRM1MaterialValues() throws {
        let vrm0 = try #require(MToonMaterialDescriptor(
            material: material(),
            materialProperty: vrm0MaterialProperty(floats: #"{"_BumpScale": 0.4}"#,
                                                   textures: #"{"_BumpMap": 1}"#)
        ))
        let vrm1 = try #require(MToonMaterialDescriptor(
            material: material(#"{"normalTexture": {"index": 1, "scale": 0.65}, "extensions": {"VRMC_materials_mtoon": {"specVersion": "1.0"}}}"#),
            materialProperty: nil
        ))

        #expect(vrm0.normalScale.isApproximatelyEqual(to: 0.4))
        #expect(vrm1.normalScale.isApproximatelyEqual(to: 0.65))
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
                            floats: String = "{}",
                            keywordMap: String,
                            tagMap: String) throws -> MToonMaterialDescriptor {
        return try #require(MToonMaterialDescriptor(
            material: material(#"{"alphaMode": "OPAQUE"}"#),
            materialProperty: vrm0MaterialProperty(renderQueue: renderQueue,
                                                   floats: floats,
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
