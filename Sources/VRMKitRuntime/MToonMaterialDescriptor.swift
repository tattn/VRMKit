import Foundation
import simd
import VRMKit

/// Canonical VRMC_materials_mtoon 1.0 material model.
///
/// This type only knows MToon 1.0 semantics. VRM 0.x materials are converted
/// by ``VRM0MToonMigrator`` before they reach this descriptor, and renderer
/// specific constraints (RealityKit, ...) are applied by the renderer layer.
package struct MToonMaterialDescriptor {
    package enum CullMode {
        case none
        case front
        case back
    }

    package enum OutlineWidthMode {
        case none
        case worldCoordinates
        case screenCoordinates
    }

    /// Shared with the standard material paths; the aliases keep this
    /// descriptor's vocabulary local.
    package typealias UVTransform = GLTFUVTransform
    package typealias Texture = GLTFSampledTexture

    package let baseColorFactor: SIMD4<Float>
    package let emissiveFactor: SIMD3<Float>
    package let shadeColorFactor: SIMD4<Float>
    package let shadingShiftFactor: Float
    package let shadingShiftTextureScale: Float
    package let shadingToonyFactor: Float
    package let giEqualizationFactor: Float
    package let matcapFactor: SIMD3<Float>
    package let parametricRimColorFactor: SIMD4<Float>
    package let rimLightingMixFactor: Float
    package let parametricRimFresnelPowerFactor: Float
    package let parametricRimLiftFactor: Float
    package let outlineWidthMode: OutlineWidthMode
    package let outlineWidthFactor: Float
    package let outlineColorFactor: SIMD4<Float>
    package let outlineLightingMixFactor: Float
    package let uvAnimationScrollXSpeedFactor: Float
    package let uvAnimationScrollYSpeedFactor: Float
    package let uvAnimationRotationSpeedFactor: Float
    package let transparentWithZWrite: Bool
    package let renderQueueOffsetNumber: Int
    package let alphaMode: GLTF.Material.AlphaMode
    package let alphaCutoff: Float
    package let cullMode: CullMode
    package let normalScale: Float
    package let baseColorTexture: Texture?
    package let emissiveTexture: Texture?
    package let shadeMultiplyTexture: Texture?
    package let shadingShiftTexture: Texture?
    package let normalTexture: Texture?
    package let matcapTexture: Texture?
    package let rimMultiplyTexture: Texture?
    package let outlineWidthMultiplyTexture: Texture?
    package let uvAnimationMaskTexture: Texture?

    // No initializers are declared in the struct body so that the implicit
    // memberwise initializer stays available to VRM0MToonMigrator.
}

package extension MToonMaterialDescriptor {
    /// The `VRMC_materials_mtoon` spec versions this descriptor implements.
    /// Anything else falls back to Unlit / PBR rather than being read with 1.0
    /// semantics.
    static func supports(specVersion: String) -> Bool {
        specVersion == "1.0" || specVersion == "1.0-beta"
    }

    init?(material: GLTF.Material, materialProperty: VRM0.MaterialProperty?) {
        if let mtoon = material.extensions?.materialsMToon {
            guard Self.supports(specVersion: mtoon.specVersion) else { return nil }
            self.init(vrm1: mtoon, material: material)
            return
        }

        guard let materialProperty,
              materialProperty.vrmShader == .mToon || materialProperty.shader.lowercased().contains("mtoon") else {
            return nil
        }
        self = VRM0MToonMigrator.migrate(property: materialProperty, material: material)
    }
}

package extension MToonMaterialDescriptor {
    /// UV-accessed textures in the order renderers should consider them when
    /// they can only honor a single material-level UV transform.
    var uvAccessedTextures: [Texture] {
        [baseColorTexture, shadeMultiplyTexture, shadingShiftTexture, normalTexture,
         emissiveTexture, rimMultiplyTexture, outlineWidthMultiplyTexture, uvAnimationMaskTexture]
            .compactMap { $0 }
    }

    var hasOutline: Bool {
        switch outlineWidthMode {
        case .none:
            return false
        case .worldCoordinates, .screenCoordinates:
            return outlineWidthFactor > 0
        }
    }
}

private extension MToonMaterialDescriptor {
    init(vrm1 mtoon: GLTF.Material.MaterialExtensions.MaterialsMToon, material: GLTF.Material) {
        let pbr = material.pbrMetallicRoughness
        let baseColor = (pbr?.baseColorFactor).map(SIMD4<Float>.init) ?? SIMD4<Float>(1, 1, 1, 1)
        let shadeColor = SIMD4<Float>(mtoon.shadeColorFactor, default: SIMD4<Float>(0, 0, 0, 1))
        let matcapFactor = SIMD3<Float>(mtoon.matcapFactor, default: SIMD3<Float>(1, 1, 1))
        let rimColor = SIMD4<Float>(mtoon.parametricRimColorFactor, default: SIMD4<Float>(0, 0, 0, 1))
        let outlineColor = SIMD4<Float>(mtoon.outlineColorFactor, default: SIMD4<Float>(0, 0, 0, 1))

        self.baseColorFactor = baseColor
        self.emissiveFactor = SIMD3<Float>(material.emissiveFactor)
        self.shadeColorFactor = shadeColor
        self.shadingShiftFactor = Float(mtoon.shadingShiftFactor ?? 0)
        self.shadingShiftTextureScale = Float(mtoon.shadingShiftTexture?.scale ?? 1)
        self.shadingToonyFactor = Float(mtoon.shadingToonyFactor ?? 0.9)
        self.giEqualizationFactor = Float(mtoon.giEqualizationFactor ?? 0.9)
        self.matcapFactor = matcapFactor
        self.parametricRimColorFactor = rimColor
        self.rimLightingMixFactor = Float(mtoon.rimLightingMixFactor ?? 1)
        self.parametricRimFresnelPowerFactor = Float(mtoon.parametricRimFresnelPowerFactor ?? 5)
        self.parametricRimLiftFactor = Float(mtoon.parametricRimLiftFactor ?? 0)
        self.outlineWidthMode = .init(vrm1: mtoon.outlineWidthMode)
        self.outlineWidthFactor = Float(mtoon.outlineWidthFactor ?? 0)
        self.outlineColorFactor = outlineColor
        self.outlineLightingMixFactor = Float(mtoon.outlineLightingMixFactor ?? 1)
        self.uvAnimationScrollXSpeedFactor = Float(mtoon.uvAnimationScrollXSpeedFactor ?? 0)
        self.uvAnimationScrollYSpeedFactor = Float(mtoon.uvAnimationScrollYSpeedFactor ?? 0)
        self.uvAnimationRotationSpeedFactor = Float(mtoon.uvAnimationRotationSpeedFactor ?? 0)
        self.transparentWithZWrite = mtoon.transparentWithZWrite ?? false
        self.renderQueueOffsetNumber = mtoon.renderQueueOffsetNumber ?? 0
        self.alphaMode = material.alphaMode
        self.alphaCutoff = material.alphaCutoff
        self.cullMode = material.doubleSided ? .none : .back
        self.normalScale = Float(material.normalTexture?.scale ?? 1)
        self.baseColorTexture = pbr?.baseColorTexture.map(MToonMaterialDescriptor.Texture.init)
        self.emissiveTexture = material.emissiveTexture.map(MToonMaterialDescriptor.Texture.init)
        self.shadeMultiplyTexture = mtoon.shadeMultiplyTexture.map(MToonMaterialDescriptor.Texture.init)
        self.shadingShiftTexture = mtoon.shadingShiftTexture.map(MToonMaterialDescriptor.Texture.init)
        self.normalTexture = material.normalTexture.map(MToonMaterialDescriptor.Texture.init)
        self.matcapTexture = mtoon.matcapTexture.map(MToonMaterialDescriptor.Texture.init)
        self.rimMultiplyTexture = mtoon.rimMultiplyTexture.map(MToonMaterialDescriptor.Texture.init)
        self.outlineWidthMultiplyTexture = mtoon.outlineWidthMultiplyTexture.map(MToonMaterialDescriptor.Texture.init)
        self.uvAnimationMaskTexture = mtoon.uvAnimationMaskTexture.map(MToonMaterialDescriptor.Texture.init)
    }
}

private extension MToonMaterialDescriptor.OutlineWidthMode {
    init(vrm1 mode: GLTF.Material.MaterialExtensions.MaterialsMToon.MaterialsMToonOutlineWidthMode?) {
        switch mode {
        case .some(.worldCoordinates):
            self = .worldCoordinates
        case .some(.screenCoordinates):
            self = .screenCoordinates
        case .some(.none), nil:
            self = .none
        }
    }
}

private extension MToonMaterialDescriptor.Texture {
    init(_ textureInfo: GLTF.Material.MaterialExtensions.MaterialsMToon.MaterialsMToonTextureInfo) {
        self.init(index: textureInfo.index, texCoord: textureInfo.texCoord ?? 0, extensions: textureInfo.extensions)
    }

    init(_ textureInfo: GLTF.Material.MaterialExtensions.MaterialsMToon.MaterialsMToonShadingShiftTexture) {
        self.init(index: textureInfo.index, texCoord: textureInfo.texCoord ?? 0, extensions: textureInfo.extensions)
    }
}
