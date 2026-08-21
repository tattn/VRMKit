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
    /// What MToon data a glTF material carries. A material authored against an
    /// unimplemented spec version *is* MToon, so renderers must tell it from one
    /// that carries no MToon data at all and is theirs to shade freely.
    enum Resolution {
        /// The material carries no MToon data.
        case none
        /// The material's MToon data, decoded.
        case supported(MToonMaterialDescriptor)
        /// The material declares `VRMC_materials_mtoon` with the given
        /// `specVersion`, which ``supports(specVersion:)`` does not implement.
        case unsupportedVersion(String)

        /// Whether the material is MToon at all, readable or not.
        package var isMToon: Bool {
            if case .none = self { return false }
            return true
        }

        /// The decoded MToon data, or nil when there is none to read.
        package var descriptor: MToonMaterialDescriptor? {
            guard case .supported(let descriptor) = self else { return nil }
            return descriptor
        }
    }

    /// The `VRMC_materials_mtoon` spec versions this descriptor implements.
    /// Anything else falls back to Unlit / PBR rather than being read with 1.0
    /// semantics.
    static func supports(specVersion: String) -> Bool {
        specVersion == "1.0" || specVersion == "1.0-beta"
    }

    /// The MToon data `material` carries, from the `VRMC_materials_mtoon`
    /// extension or, for VRM 0.x, the Unity material property describing it.
    static func resolve(material: GLTF.Material,
                        materialProperty: VRM0.MaterialProperty?) -> Resolution {
        if let mtoon = material.extensions?.materialsMToon {
            guard supports(specVersion: mtoon.specVersion) else {
                return .unsupportedVersion(mtoon.specVersion)
            }
            return .supported(MToonMaterialDescriptor(vrm1: mtoon, material: material))
        }

        guard let materialProperty,
              materialProperty.vrmShader == .mToon || materialProperty.shader.lowercased().contains("mtoon") else {
            return .none
        }
        return .supported(VRM0MToonMigrator.migrate(property: materialProperty, material: material))
    }

    /// The decoded MToon data, or nil when there is none this descriptor can
    /// read. ``resolve(material:materialProperty:)`` tells those two apart.
    init?(material: GLTF.Material, materialProperty: VRM0.MaterialProperty?) {
        guard let descriptor = Self.resolve(material: material,
                                            materialProperty: materialProperty).descriptor else {
            return nil
        }
        self = descriptor
    }
}

package extension MToonMaterialDescriptor {
    /// MToon 1.0 spec defaults, used as fallbacks for omitted authored values
    /// and synthesized standard materials.
    enum SpecDefault {
        package static let shadingShiftFactor: Float = 0
        static let shadingShiftTextureScale: Float = 1
        package static let shadingToonyFactor: Float = 0.9
        static let giEqualizationFactor: Float = 0.9
        static let matcapFactor = SIMD3<Float>(1, 1, 1)
        static let parametricRimColorFactor = SIMD4<Float>(0, 0, 0, 1)
        static let rimLightingMixFactor: Float = 1
        static let parametricRimFresnelPowerFactor: Float = 5
        static let parametricRimLiftFactor: Float = 0
        package static let outlineWidthFactor: Float = 0
        package static let outlineColorFactor = SIMD4<Float>(0, 0, 0, 1)
        static let outlineLightingMixFactor: Float = 1
        static let uvAnimationSpeedFactor: Float = 0
        static let transparentWithZWrite = false
        static let renderQueueOffsetNumber = 0
    }

    /// The fields every descriptor derives the same way from the standard glTF
    /// material, whether the toon values are authored or synthesized.
    struct StandardMaterialProperties {
        let baseColorFactor: SIMD4<Float>
        let emissiveFactor: SIMD3<Float>
        let alphaMode: GLTF.Material.AlphaMode
        let alphaCutoff: Float
        let cullMode: CullMode
        let normalScale: Float
        let baseColorTexture: Texture?
        let emissiveTexture: Texture?
        let normalTexture: Texture?

        init(_ material: GLTF.Material) {
            let pbr = material.pbrMetallicRoughness
            baseColorFactor = (pbr?.baseColorFactor).map(SIMD4<Float>.init) ?? SIMD4<Float>(1, 1, 1, 1)
            emissiveFactor = SIMD3<Float>(material.emissiveFactor)
            alphaMode = material.alphaMode
            alphaCutoff = material.alphaCutoff
            cullMode = material.doubleSided ? .none : .back
            normalScale = Float(material.normalTexture?.scale ?? 1)
            baseColorTexture = pbr?.baseColorTexture.map(Texture.init)
            emissiveTexture = material.emissiveTexture.map(Texture.init)
            normalTexture = material.normalTexture.map(Texture.init)
        }
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
        let standard = StandardMaterialProperties(material)

        self.baseColorFactor = standard.baseColorFactor
        self.emissiveFactor = standard.emissiveFactor
        self.shadeColorFactor = SIMD4<Float>(mtoon.shadeColorFactor, default: SIMD4<Float>(0, 0, 0, 1))
        self.shadingShiftFactor = mtoon.shadingShiftFactor.map(Float.init) ?? SpecDefault.shadingShiftFactor
        self.shadingShiftTextureScale = (mtoon.shadingShiftTexture?.scale).map(Float.init)
            ?? SpecDefault.shadingShiftTextureScale
        self.shadingToonyFactor = mtoon.shadingToonyFactor.map(Float.init) ?? SpecDefault.shadingToonyFactor
        self.giEqualizationFactor = mtoon.giEqualizationFactor.map(Float.init) ?? SpecDefault.giEqualizationFactor
        self.matcapFactor = SIMD3<Float>(mtoon.matcapFactor, default: SpecDefault.matcapFactor)
        self.parametricRimColorFactor = SIMD4<Float>(mtoon.parametricRimColorFactor,
                                                     default: SpecDefault.parametricRimColorFactor)
        self.rimLightingMixFactor = mtoon.rimLightingMixFactor.map(Float.init) ?? SpecDefault.rimLightingMixFactor
        self.parametricRimFresnelPowerFactor = mtoon.parametricRimFresnelPowerFactor.map(Float.init)
            ?? SpecDefault.parametricRimFresnelPowerFactor
        self.parametricRimLiftFactor = mtoon.parametricRimLiftFactor.map(Float.init)
            ?? SpecDefault.parametricRimLiftFactor
        self.outlineWidthMode = .init(vrm1: mtoon.outlineWidthMode)
        self.outlineWidthFactor = mtoon.outlineWidthFactor.map(Float.init) ?? SpecDefault.outlineWidthFactor
        self.outlineColorFactor = SIMD4<Float>(mtoon.outlineColorFactor, default: SpecDefault.outlineColorFactor)
        self.outlineLightingMixFactor = mtoon.outlineLightingMixFactor.map(Float.init)
            ?? SpecDefault.outlineLightingMixFactor
        self.uvAnimationScrollXSpeedFactor = mtoon.uvAnimationScrollXSpeedFactor.map(Float.init)
            ?? SpecDefault.uvAnimationSpeedFactor
        self.uvAnimationScrollYSpeedFactor = mtoon.uvAnimationScrollYSpeedFactor.map(Float.init)
            ?? SpecDefault.uvAnimationSpeedFactor
        self.uvAnimationRotationSpeedFactor = mtoon.uvAnimationRotationSpeedFactor.map(Float.init)
            ?? SpecDefault.uvAnimationSpeedFactor
        self.transparentWithZWrite = mtoon.transparentWithZWrite ?? SpecDefault.transparentWithZWrite
        self.renderQueueOffsetNumber = mtoon.renderQueueOffsetNumber ?? SpecDefault.renderQueueOffsetNumber
        self.alphaMode = standard.alphaMode
        self.alphaCutoff = standard.alphaCutoff
        self.cullMode = standard.cullMode
        self.normalScale = standard.normalScale
        self.baseColorTexture = standard.baseColorTexture
        self.emissiveTexture = standard.emissiveTexture
        self.shadeMultiplyTexture = mtoon.shadeMultiplyTexture.map(MToonMaterialDescriptor.Texture.init)
        self.shadingShiftTexture = mtoon.shadingShiftTexture.map(MToonMaterialDescriptor.Texture.init)
        self.normalTexture = standard.normalTexture
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
