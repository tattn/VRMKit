import Foundation
import simd
import VRMKit

/// Converts VRM 0.x MToon material properties into VRMC_materials_mtoon 1.0
/// semantics, following UniVRM's `MToon10Migrator` as the migration oracle.
///
/// This layer knows nothing about renderers; it only maps VRM 0.x Unity
/// shader properties onto the canonical ``MToonMaterialDescriptor``.
package enum VRM0MToonMigrator {
    package static func migrate(property: VRM0.MaterialProperty,
                                material: GLTF.Material) -> MToonMaterialDescriptor {
        let floats = property.floatProperties.dictionaryValue
        let textures = property.textureProperties
        let vectors = property.vectorProperties.dictionaryValue
        let pbr = material.pbrMetallicRoughness

        // VRM 0.x stores Lit / Shade / Rim / Outline colors as sRGB, while
        // MToon 1.0 factors are linear. UniVRM treats emission and the glTF
        // baseColorFactor fallback as already linear.
        let baseColor = vectors.simd4("_Color").map(srgbToLinear)
            ?? (pbr?.baseColorFactor).map(SIMD4<Float>.init)
            ?? SIMD4<Float>(1, 1, 1, 1)
        let emissiveColor = vectors.simd3("_EmissionColor") ?? SIMD3<Float>(0, 0, 0)
        let shadeColor = srgbToLinear(vectors.simd4("_ShadeColor") ?? SIMD4<Float>(0.97, 0.81, 0.86, 1))
        let rimColor = srgbToLinear(vectors.simd4("_RimColor") ?? SIMD4<Float>(0, 0, 0, 1))
        let outlineColor = srgbToLinear(vectors.simd4("_OutlineColor") ?? SIMD4<Float>(0, 0, 0, 1))

        let alphaMode = GLTF.Material.AlphaMode(vrm0: property, fallback: material.alphaMode)
        // MToon 0.x has no `_ZWRITE_ON` shader keyword: the render mode lives in
        // `_BlendMode` (3 = TransparentWithZWrite), which is what MToon10Migrator
        // reads. `_ZWrite` is derived state, so it only separates the two
        // transparent modes -- opaque materials write depth as well.
        let transparentWithZWrite: Bool
        switch floats.float("_BlendMode") {
        case .some(3):
            transparentWithZWrite = true
        case .some:
            transparentWithZWrite = false
        default:
            transparentWithZWrite = alphaMode == .BLEND && floats.float("_ZWrite") == 1
        }
        let cullMode: MToonMaterialDescriptor.CullMode
        switch floats.float("_CullMode") {
        case .some(0):
            cullMode = .none
        case .some(1):
            cullMode = .front
        case .some(2):
            cullMode = .back
        default:
            cullMode = material.doubleSided ? .none : .back
        }
        let hasMToonNormalTexture = textures["_BumpMap"] != nil
        let shadeShift0 = floats.float("_ShadeShift") ?? 0
        let shadeToony0 = floats.float("_ShadeToony") ?? 0.9
        let rangeMin = shadeShift0
        let rangeMax = simd_mix(Float(1), shadeShift0, shadeToony0)

        let outlineWidthMode = MToonMaterialDescriptor.OutlineWidthMode(vrm0: floats.float("_OutlineWidthMode") ?? 0)
        let outlineWidthFactor: Float
        switch outlineWidthMode {
        case .none:
            outlineWidthFactor = 0
        case .worldCoordinates:
            // VRM 0.x expresses world-space outline width in centimeters.
            outlineWidthFactor = (floats.float("_OutlineWidth") ?? 0) * 0.01
        case .screenCoordinates:
            // UniVRM halves screen-space width during 0.x -> 1.0 migration.
            outlineWidthFactor = (floats.float("_OutlineWidth") ?? 0) * 0.01 * 0.5
        }
        let outlineLightingMixFactor: Float
        switch floats.float("_OutlineColorMode") ?? 0 {
        case 0: // FixedColor renders the outline unlit.
            outlineLightingMixFactor = 0
        default: // MixedLighting keeps the source mix value.
            outlineLightingMixFactor = floats.float("_OutlineLightingMix") ?? 1
        }

        // UniVRM keeps the _MainTex scale/offset as the material's texture
        // transform during migration; MToon 0.x applied it to every texture.
        let mainTransform = mainTextureTransform(vectors: vectors)
        func texture(_ index: Int?) -> MToonMaterialDescriptor.Texture? {
            index.map { .init(index: $0, texCoord: 0, transform: mainTransform) }
        }

        return MToonMaterialDescriptor(
            baseColorFactor: baseColor,
            emissiveFactor: emissiveColor,
            shadeColorFactor: shadeColor,
            shadingShiftFactor: (-(rangeMax + rangeMin) / 2).clamped(to: -1 ... 1),
            shadingShiftTextureScale: 1,
            shadingToonyFactor: ((2 - (rangeMax - rangeMin)) / 2).clamped(to: 0 ... 1),
            giEqualizationFactor: (1 - (floats.float("_IndirectLightIntensity") ?? 0.1)).clamped(to: 0 ... 1),
            matcapFactor: SIMD3<Float>(1, 1, 1),
            parametricRimColorFactor: rimColor,
            // UniVRM migrates rim lighting mix destructively to 1.0 for
            // visual compatibility; the 0.x source value is intentionally dropped.
            rimLightingMixFactor: 1,
            parametricRimFresnelPowerFactor: floats.float("_RimFresnelPower") ?? 1,
            parametricRimLiftFactor: floats.float("_RimLift") ?? 0,
            outlineWidthMode: outlineWidthMode,
            outlineWidthFactor: outlineWidthFactor,
            outlineColorFactor: outlineColor,
            outlineLightingMixFactor: outlineLightingMixFactor,
            uvAnimationScrollXSpeedFactor: floats.float("_UvAnimScrollX") ?? 0,
            // UniVRM inverts the Y scroll direction during migration.
            uvAnimationScrollYSpeedFactor: -(floats.float("_UvAnimScrollY") ?? 0),
            uvAnimationRotationSpeedFactor: (floats.float("_UvAnimRotation") ?? 0) * 2 * Float.pi,
            transparentWithZWrite: transparentWithZWrite,
            // renderQueueOffsetNumber is a *relative* order among a model's
            // transparent materials; a single material carries no such ordering,
            // so Unity's absolute renderQueue cannot be migrated here.
            renderQueueOffsetNumber: 0,
            alphaMode: alphaMode,
            alphaCutoff: floats.float("_Cutoff") ?? material.alphaCutoff,
            cullMode: cullMode,
            normalScale: hasMToonNormalTexture
                ? (floats.float("_BumpScale") ?? 1)
                : Float(material.normalTexture?.scale ?? 1),
            baseColorTexture: texture(textures["_MainTex"]),
            emissiveTexture: texture(textures["_EmissionMap"]),
            shadeMultiplyTexture: texture(textures["_ShadeTexture"] ?? textures["_MainTex"]),
            shadingShiftTexture: nil,
            normalTexture: texture(textures["_BumpMap"])
                ?? material.normalTexture.map { .init(index: $0.index, texCoord: $0.texCoord) },
            matcapTexture: texture(textures["_SphereAdd"]),
            rimMultiplyTexture: texture(textures["_RimTexture"]),
            outlineWidthMultiplyTexture: texture(textures["_OutlineWidthTexture"]),
            uvAnimationMaskTexture: texture(textures["_UvAnimMaskTexture"])
        )
    }

    /// Converts Unity `_MainTex` scale/offset (bottom-left UV origin) into
    /// KHR_texture_transform semantics (top-left origin). Returns nil for the
    /// identity transform.
    static func mainTextureTransform(vectors: [String: Any]) -> MToonMaterialDescriptor.UVTransform? {
        guard let values = vectors["_MainTex"] as? [Any], values.count >= 4 else {
            return nil
        }
        let offsetX = values.float(at: 0, default: 0)
        let offsetY = values.float(at: 1, default: 0)
        let scaleX = values.float(at: 2, default: 1)
        let scaleY = values.float(at: 3, default: 1)
        guard offsetX != 0 || offsetY != 0 || scaleX != 1 || scaleY != 1 else {
            return nil
        }
        return .init(scale: SIMD2<Float>(scaleX, scaleY),
                     offset: SIMD2<Float>(offsetX, 1 - offsetY - scaleY),
                     rotation: 0)
    }

    static func srgbToLinear(_ value: Float) -> Float {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    static func srgbToLinear(_ value: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(srgbToLinear(value.x),
                     srgbToLinear(value.y),
                     srgbToLinear(value.z),
                     value.w)
    }
}

private extension MToonMaterialDescriptor.OutlineWidthMode {
    init(vrm0 mode: Float) {
        switch mode {
        case 1:
            self = .worldCoordinates
        case 2:
            self = .screenCoordinates
        default:
            self = .none
        }
    }
}

package extension GLTF.Material.AlphaMode {
    /// Resolves the glTF alpha mode from VRM 0.x Unity shader metadata.
    /// `RenderType` takes priority over the keyword map, matching UniVRM.
    init(vrm0 property: VRM0.MaterialProperty?, fallback: GLTF.Material.AlphaMode) {
        guard let property else {
            self = fallback
            return
        }
        if let renderType = property.tagMap["RenderType"]?.lowercased() {
            switch renderType {
            case "opaque":
                self = .OPAQUE
                return
            case "transparentcutout", "cutout":
                self = .MASK
                return
            case "transparent":
                self = .BLEND
                return
            default:
                break
            }
        }

        if property.vrmShader == .unlitTransparent
            || property.keywordMap["_ALPHAPREMULTIPLY_ON"] == true
            || property.keywordMap["_ALPHABLEND_ON"] == true {
            self = .BLEND
        } else if property.keywordMap["_ALPHATEST_ON"] == true {
            self = .MASK
        } else {
            self = fallback
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
