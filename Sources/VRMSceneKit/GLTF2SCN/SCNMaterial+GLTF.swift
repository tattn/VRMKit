import VRMKit
import SceneKit
import SpriteKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNMaterial {
    convenience init(material: GLTF.Material, at index: Int, loader: VRMSceneLoader) throws {
        self.init()
        name = material.name
        let mtoon = material.extensions?.materialsMToon
        let isMToon = mtoon != nil
        let isUnlit = material.extensions?.materialsUnlit != nil
        let isVRM0: Bool
        switch loader.vrm {
        case .v0: isVRM0 = true
        case .v1: isVRM0 = false
        }

        var shader: VRM0.MaterialProperty.Shader?
        writesToDepthBuffer = mtoon?.transparentWithZWrite == true || material.alphaMode != .BLEND

        if let property = loader.vrm0MaterialProperty(at: index) {
            shader = property.vrmShader
            // FIXME/TODO: https://dwango.github.io/vrm/vrm_spec/#vrm%E3%81%8C%E6%8F%90%E4%BE%9B%E3%81%99%E3%82%8B%E3%82%B7%E3%82%A7%E3%83%BC%E3%83%80%E3%83%BC
            if shader == .unlitTransparent {
                blendMode = .alpha
                writesToDepthBuffer = false
            } else if property.keywordMap["_ALPHAPREMULTIPLY_ON"] ?? false {
                blendMode = .alpha
            } else {
                blendMode = blendMode(of: material.alphaMode)
            }
        } else {
            blendMode = blendMode(of: material.alphaMode)
        }

        // A VRM 0.x model shades through its Unity shader, save for
        // `VRM_USE_GLTFSHADER`, which asks for the glTF material as it is.
        let usesUnityShader = isVRM0 && shader != .gltfShader
        let usesConstantLighting = usesUnityShader || shader == .mToon || shader == .unlitTransparent
            || isMToon || isUnlit
        lightingModel = usesConstantLighting ? .constant : .physicallyBased
        isDoubleSided = material.doubleSided
        isLitPerPixel = !usesConstantLighting

        if let pbr = material.pbrMetallicRoughness {
            // https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#metallic-roughness-material

            if let baseTexture = pbr.baseColorTexture {
                try diffuse.setTexture(.init(baseTexture), loader: loader)
                // glTF multiplies the base texture by the factor, and `multiply`
                // is where SceneKit takes it. MToon overwrites it below.
                multiply.contents = pbr.baseColorFactor.createSKColor()
            } else {
                diffuse.contents = pbr.baseColorFactor.createSKColor()
            }

            if let metallicTexture = pbr.metallicRoughnessTexture {
                try metalness.setTexture(.init(metallicTexture), loader: loader)
                try roughness.setTexture(.init(metallicTexture), loader: loader)

                let image = try metalness.contents as? VRMImage ??? ._dataInconsistent("failed to load texture image")
                let (metalTexture, roughTexture) = try createMetallicRoughnessTexture(from: image, of: pbr)
                metalness.contents = metalTexture
                roughness.contents = roughTexture
            } else {
                metalness.contents = SKColor(white: CGFloat(pbr.metallicFactor), alpha: 1)
                roughness.contents = SKColor(white: CGFloat(pbr.roughnessFactor), alpha: 1)
            }
        }

        if let normalTexture = material.normalTexture {
            try normal.setTexture(.init(normalTexture), loader: loader)
        }

        if let occlusionTexture = material.occlusionTexture {
            try ambientOcclusion.setTexture(.init(occlusionTexture), loader: loader)
            ambientOcclusion.intensity = CGFloat(occlusionTexture.strength)
        }

        let emissiveFactor = material.emissiveFactor
        if let emissiveTexture = material.emissiveTexture {
            try emission.setTexture(.init(emissiveTexture), loader: loader)
            // The factor multiplies the sampled emission, and its strongest
            // channel is as much of that as an intensity can carry.
            emission.intensity = CGFloat(emissiveFactor.max())
        } else if emissiveFactor != .zero {
            emission.contents = emissiveFactor.createSKColor(alpha: 1)
        }

        if material.alphaMode == .MASK {
            applyAlphaCutoff(material.alphaCutoff)
        }

        if let mtoon {
            try applyMToon(mtoon, material: material, loader: loader)
        }
    }

    /// glTF draws a `MASK` material opaque at the cutoff and not at all below it,
    /// which SceneKit, having no cutoff of its own, has to discard for.
    private func applyAlphaCutoff(_ cutoff: Float) {
        shaderModifiers = [
            .fragment: "if (_output.color.a < \(cutoff)) { discard_fragment(); }"
        ]
    }

    private func applyMToon(_ mtoon: GLTF.Material.MaterialExtensions.MaterialsMToon,
                            material: GLTF.Material,
                            loader: VRMSceneLoader) throws {
        if let shadeColor = mtoon.shadeColorFactor {
            multiply.contents = SKColor(color3: shadeColor, alpha: 1.0)
        }
        if let shadeTexture = mtoon.shadeMultiplyTexture {
            try multiply.setTexture(.init(shadeTexture), loader: loader)
        }
        if let matcapTexture = mtoon.matcapTexture {
            try reflective.setTexture(.init(matcapTexture), loader: loader)
        }
        if let rimColor = mtoon.parametricRimColorFactor {
            selfIllumination.contents = SKColor(color3: rimColor, alpha: 1.0)
            selfIllumination.intensity = CGFloat(mtoon.parametricRimLiftFactor ?? 0)
        }
        if let rimTexture = mtoon.rimMultiplyTexture {
            try selfIllumination.setTexture(.init(rimTexture), loader: loader)
        }
        if let outlineColor = mtoon.outlineColorFactor {
            transparent.contents = SKColor(color3: outlineColor, alpha: 1.0)
        }
        if let uvMask = mtoon.uvAnimationMaskTexture {
            try ambient.setTexture(.init(uvMask), loader: loader)
        }
        if material.alphaMode == .BLEND || mtoon.transparentWithZWrite == true {
            blendMode = .alpha
        }
    }

    private func createMetallicRoughnessTexture(
        from uiImage: VRMImage,
        of pbr: GLTF.Material.PbrMetallicRoughness
    ) throws -> (metal: VRMImage, rough: VRMImage) {
        let image = try uiImage.cgImage ??? ._dataInconsistent("failed to get cgImage")
        // SceneKit modulates neither property, so the factors are baked in.
        let images = try metallicRoughnessImages(from: image,
                                                 metallicFactor: pbr.metallicFactor,
                                                 roughnessFactor: pbr.roughnessFactor)
        return (VRMImage(cgImage: images.metal), VRMImage(cgImage: images.rough))
    }

    private func blendMode(of alphaMode: GLTF.Material.AlphaMode) -> SCNBlendMode {
        // FIXME/TODO: https://dwango.github.io/vrm/vrm_spec/#vrm%E3%81%8C%E6%8F%90%E4%BE%9B%E3%81%99%E3%82%8B%E3%82%B7%E3%82%A7%E3%83%BC%E3%83%80%E3%83%BC
        switch alphaMode {
        case .OPAQUE: return .replace
        case .BLEND: return .alpha // FIXME/TODO: blend shader
        // Nothing survives the cutoff part-way, so it draws as an opaque one.
        case .MASK: return .replace
        }
    }
}
