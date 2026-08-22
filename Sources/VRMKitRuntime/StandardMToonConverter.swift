import VRMKit

/// Synthesizes an ``MToonMaterialDescriptor`` from a standard Unlit / PBR glTF
/// material, the way ``VRM0MToonMigrator`` does from a VRM 0.x property.
package enum StandardMToonConverter {
    package static func migrate(material: GLTF.Material,
                                vrm0Property: VRM0.MaterialProperty?,
                                shadeColorScale: Float,
                                shadingToonyFactor: Float,
                                shadingShiftFactor: Float,
                                outlineWidthMode: MToonMaterialDescriptor.OutlineWidthMode,
                                outlineWidthFactor: Float,
                                outlineColorFactor: SIMD4<Float>) -> MToonMaterialDescriptor {
        typealias SpecDefault = MToonMaterialDescriptor.SpecDefault
        let standard = MToonMaterialDescriptor.StandardMaterialProperties(material)
        let base = standard.baseColorFactor
        let shadeColor = SIMD4<Float>(SIMD3<Float>(base.x, base.y, base.z) * shadeColorScale, 1)
        let hasOutline = outlineWidthFactor > 0

        return MToonMaterialDescriptor(
            baseColorFactor: standard.baseColorFactor,
            emissiveFactor: standard.emissiveFactor,
            shadeColorFactor: shadeColor,
            shadingShiftFactor: shadingShiftFactor,
            shadingShiftTextureScale: SpecDefault.shadingShiftTextureScale,
            shadingToonyFactor: shadingToonyFactor,
            giEqualizationFactor: SpecDefault.giEqualizationFactor,
            matcapFactor: SpecDefault.matcapFactor,
            parametricRimColorFactor: SpecDefault.parametricRimColorFactor,
            rimLightingMixFactor: SpecDefault.rimLightingMixFactor,
            parametricRimFresnelPowerFactor: SpecDefault.parametricRimFresnelPowerFactor,
            parametricRimLiftFactor: SpecDefault.parametricRimLiftFactor,
            outlineWidthMode: hasOutline ? outlineWidthMode : .none,
            outlineWidthFactor: outlineWidthFactor,
            outlineColorFactor: outlineColorFactor,
            outlineLightingMixFactor: SpecDefault.outlineLightingMixFactor,
            uvAnimationScrollXSpeedFactor: SpecDefault.uvAnimationSpeedFactor,
            uvAnimationScrollYSpeedFactor: SpecDefault.uvAnimationSpeedFactor,
            uvAnimationRotationSpeedFactor: SpecDefault.uvAnimationSpeedFactor,
            transparentWithZWrite: SpecDefault.transparentWithZWrite,
            renderQueueOffsetNumber: SpecDefault.renderQueueOffsetNumber,
            // A VRM 0.x non-MToon material carries its transparency in the Unity
            // property, resolved the same way as the built-in Unlit / PBR path.
            alphaMode: GLTF.Material.AlphaMode(vrm0: vrm0Property, fallback: standard.alphaMode),
            alphaCutoff: standard.alphaCutoff,
            cullMode: standard.cullMode,
            normalScale: standard.normalScale,
            baseColorTexture: standard.baseColorTexture,
            emissiveTexture: standard.emissiveTexture,
            shadeMultiplyTexture: standard.baseColorTexture,
            shadingShiftTexture: nil,
            normalTexture: standard.normalTexture,
            matcapTexture: nil,
            rimMultiplyTexture: nil,
            outlineWidthMultiplyTexture: nil,
            uvAnimationMaskTexture: nil
        )
    }
}
