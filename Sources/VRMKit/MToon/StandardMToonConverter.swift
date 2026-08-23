import simd

/// Synthesizes an ``MToonMaterialDescriptor`` from a standard Unlit / PBR glTF
/// material, the way ``VRM0MToonProperty`` does from a VRM 0.x property.
///
/// One conversion serves both users of it: the renderer toon-shading a model
/// that carries no MToon data, and the writer saving one with MToon materials.
package enum StandardMToonConverter {
    package static func convert(material: GLTF.Material,
                                vrm0Property: VRM0.MaterialProperty? = nil,
                                style: MToonConversionStyle) -> MToonMaterialDescriptor {
        typealias SpecDefault = MToonMaterialDescriptor.SpecDefault
        let standard = MToonMaterialDescriptor.StandardMaterialProperties(material)
        let base = standard.baseColorFactor
        let shadeColor = SIMD4<Float>(SIMD3<Float>(base.x, base.y, base.z) * style.shadeColorScale, 1)

        return MToonMaterialDescriptor(
            baseColorFactor: standard.baseColorFactor,
            emissiveFactor: standard.emissiveFactor,
            shadeColorFactor: shadeColor,
            shadingShiftFactor: style.shadingShiftFactor,
            shadingShiftTextureScale: SpecDefault.shadingShiftTextureScale,
            shadingToonyFactor: style.shadingToonyFactor,
            giEqualizationFactor: SpecDefault.giEqualizationFactor,
            matcapFactor: SpecDefault.matcapFactor,
            parametricRimColorFactor: SpecDefault.parametricRimColorFactor,
            rimLightingMixFactor: SpecDefault.rimLightingMixFactor,
            parametricRimFresnelPowerFactor: SpecDefault.parametricRimFresnelPowerFactor,
            parametricRimLiftFactor: SpecDefault.parametricRimLiftFactor,
            outlineWidthMode: style.outline.mode,
            outlineWidthFactor: style.outline.width,
            outlineColorFactor: style.outlineColorFactor,
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
