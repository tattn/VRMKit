import Foundation
import simd

/// Canonical `VRMC_materials_mtoon` 1.0 material model, and the one every MToon
/// value in this package passes through.
///
/// The extension, the VRM 0.x material property and a converted standard
/// material all become one of these, and writing takes the same routes back
/// out, so each format is read and written by one mapping rather than two.
///
/// This type knows only MToon 1.0 semantics: VRM 0.x is converted by
/// ``VRM0MToonProperty`` first, and renderer constraints belong to the
/// renderer layer.
package struct MToonMaterialDescriptor: Equatable, Sendable {
    package enum CullMode {
        case none
        case front
        case back
    }

    package typealias OutlineWidthMode = MToonOutlineWidthMode

    /// Shared with the standard material paths; the aliases keep the
    /// descriptor's vocabulary local.
    package typealias UVTransform = GLTFUVTransform
    package typealias Texture = GLTFSampledTexture

    package var baseColorFactor: SIMD4<Float>
    package var emissiveFactor: SIMD3<Float>
    package var shadeColorFactor: SIMD4<Float>
    package var shadingShiftFactor: Float
    package var shadingShiftTextureScale: Float
    package var shadingToonyFactor: Float
    package var giEqualizationFactor: Float
    package var matcapFactor: SIMD3<Float>
    package var parametricRimColorFactor: SIMD4<Float>
    package var rimLightingMixFactor: Float
    package var parametricRimFresnelPowerFactor: Float
    package var parametricRimLiftFactor: Float
    package var outlineWidthMode: OutlineWidthMode
    package var outlineWidthFactor: Float
    package var outlineColorFactor: SIMD4<Float>
    package var outlineLightingMixFactor: Float
    package var uvAnimationScrollXSpeedFactor: Float
    package var uvAnimationScrollYSpeedFactor: Float
    package var uvAnimationRotationSpeedFactor: Float
    package var transparentWithZWrite: Bool
    package var renderQueueOffsetNumber: Int
    package var alphaMode: GLTF.Material.AlphaMode
    package var alphaCutoff: Float
    package var cullMode: CullMode
    package var normalScale: Float
    package var baseColorTexture: Texture?
    package var emissiveTexture: Texture?
    package var shadeMultiplyTexture: Texture?
    package var shadingShiftTexture: Texture?
    package var normalTexture: Texture?
    package var matcapTexture: Texture?
    package var rimMultiplyTexture: Texture?
    package var outlineWidthMultiplyTexture: Texture?
    package var uvAnimationMaskTexture: Texture?

    // No initializers are declared in the struct body so that the implicit
    // memberwise initializer stays available to VRM0MToonProperty.
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
        return .supported(VRM0MToonProperty.descriptor(property: materialProperty, material: material))
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
        static let shadeColorFactor = SIMD4<Float>(1, 1, 1, 1)
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
            emissiveFactor = material.emissiveFactor
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
        self.shadeColorFactor = SIMD4<Float>(mtoon.shadeColorFactor, default: SpecDefault.shadeColorFactor)
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
        self.outlineWidthMode = mtoon.outlineWidthMode ?? .none
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
        self.shadeMultiplyTexture = mtoon.shadeMultiplyTexture.map(Texture.init)
        self.shadingShiftTexture = mtoon.shadingShiftTexture.map(Texture.init)
        self.normalTexture = standard.normalTexture
        self.matcapTexture = mtoon.matcapTexture.map(Texture.init)
        self.rimMultiplyTexture = mtoon.rimMultiplyTexture.map(Texture.init)
        self.outlineWidthMultiplyTexture = mtoon.outlineWidthMultiplyTexture.map(Texture.init)
        self.uvAnimationMaskTexture = mtoon.uvAnimationMaskTexture.map(Texture.init)
    }
}

// MARK: - Writing

package extension MToonMaterialDescriptor {
    /// The `VRMC_materials_mtoon` extension object, the inverse of
    /// ``init(vrm1:material:)``.
    ///
    /// Only the MToon fields: the base color, the emission, the alpha mode and
    /// the normal map belong to the glTF material the extension sits on, which
    /// is where they were read from. `shadingShiftTextureScale` rides on the
    /// shading shift texture, so a scale without one writes neither.
    func mtoonExtension() -> JSONObject {
        var mtoon: JSONObject = [
            "specVersion": Self.writtenSpecVersion,
            "transparentWithZWrite": transparentWithZWrite,
            "renderQueueOffsetNumber": renderQueueOffsetNumber,
            "shadeColorFactor": Self.rgb(shadeColorFactor),
            "shadingShiftFactor": Self.clamped(shadingShiftFactor, to: -1...1),
            "shadingToonyFactor": Self.clamped(shadingToonyFactor),
            "giEqualizationFactor": Self.clamped(giEqualizationFactor),
            "matcapFactor": Self.rgb(SIMD4(matcapFactor, 1)),
            "parametricRimColorFactor": Self.rgb(parametricRimColorFactor),
            "rimLightingMixFactor": Self.clamped(rimLightingMixFactor),
            "parametricRimFresnelPowerFactor": Self.clamped(parametricRimFresnelPowerFactor, to: 0...Float.infinity),
            "parametricRimLiftFactor": parametricRimLiftFactor,
            "outlineWidthMode": outlineWidthMode.rawValue,
            "outlineWidthFactor": Self.clamped(outlineWidthFactor, to: 0...Float.infinity),
            "outlineColorFactor": Self.rgb(outlineColorFactor),
            "outlineLightingMixFactor": Self.clamped(outlineLightingMixFactor),
            "uvAnimationScrollXSpeedFactor": uvAnimationScrollXSpeedFactor,
            "uvAnimationScrollYSpeedFactor": uvAnimationScrollYSpeedFactor,
            "uvAnimationRotationSpeedFactor": uvAnimationRotationSpeedFactor,
        ]
        mtoon.set("shadeMultiplyTexture", shadeMultiplyTexture?.textureInfo())
        mtoon.set("matcapTexture", matcapTexture?.textureInfo())
        mtoon.set("rimMultiplyTexture", rimMultiplyTexture?.textureInfo())
        mtoon.set("outlineWidthMultiplyTexture", outlineWidthMultiplyTexture?.textureInfo())
        mtoon.set("uvAnimationMaskTexture", uvAnimationMaskTexture?.textureInfo())
        if let shadingShiftTexture {
            var info = shadingShiftTexture.textureInfo()
            info["scale"] = shadingShiftTextureScale
            mtoon["shadingShiftTexture"] = info
        }
        return mtoon
    }

    /// Every texture the material samples, which tells a writer whether the
    /// document has to declare `KHR_texture_transform`. The matcap is sampled
    /// by view direction rather than by UV, so it is the one slot
    /// ``uvAccessedTextures`` leaves out.
    var textures: [Texture] {
        uvAccessedTextures + [matcapTexture].compactMap { $0 }
    }

    /// The newest version ``supports(specVersion:)`` reads.
    static let writtenSpecVersion = "1.0"

    /// MToon bounds the factors it defines, while a descriptor may have been
    /// assembled by a renderer override that does not.
    private static func clamped(_ value: Float, to range: ClosedRange<Float> = 0...1) -> Float {
        value.clamped(to: range)
    }

    private static func rgb(_ color: SIMD4<Float>) -> [Float] {
        [clamped(color.x), clamped(color.y), clamped(color.z)]
    }
}
