import VRMKit
import SceneKit
import SpriteKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNMaterial {
    convenience init(material: GLTF.Material, loader: VRMSceneLoader) throws {
        self.init()
        name = material.name
        let isUnlit = material.extensions?.materialsUnlit != nil
        let materialProperty = name.flatMap(loader.vrm0MaterialProperty(named:))
        let mtoon = MToonMaterialDescriptor(material: material, materialProperty: materialProperty)
        let isMToon = mtoon != nil
        let isVRM0: Bool
        switch loader.vrm {
        case .v0:
            isVRM0 = true
        case .v1:
            isVRM0 = false
        }

        var shader: VRM0.MaterialProperty.Shader?
        writesToDepthBuffer = mtoon?.transparentWithZWrite == true || material.alphaMode != .BLEND

        if let materialProperty {
            shader = materialProperty.vrmShader
            // FIXME/TODO: https://dwango.github.io/vrm/vrm_spec/#vrm%E3%81%8C%E6%8F%90%E4%BE%9B%E3%81%99%E3%82%8B%E3%82%B7%E3%82%A7%E3%83%BC%E3%83%80%E3%83%BC
            if shader == .unlitTransparent {
                blendMode = .alpha
                writesToDepthBuffer = false
            } else if materialProperty.keywordMap["_ALPHAPREMULTIPLY_ON"] ?? false {
                blendMode = .alpha
            } else {
                blendMode = blendMode(of: material.alphaMode)
            }
        } else {
            blendMode = blendMode(of: material.alphaMode)
        }

        let usesConstantLighting = isVRM0 || shader == .mToon || shader == .unlitTransparent || isMToon || isUnlit
        lightingModel = usesConstantLighting ? .constant : .physicallyBased
        isDoubleSided = material.doubleSided
        isLitPerPixel = !usesConstantLighting

        if let pbr = material.pbrMetallicRoughness {
            // https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#metallic-roughness-material

            if let baseTexture = pbr.baseColorTexture {
                try diffuse.setTextureInfo(baseTexture, loader: loader)
            } else {
                diffuse.contents = pbr.baseColorFactor.createSKColor()
            }

            if let metallicTexture = pbr.metallicRoughnessTexture {
                try metalness.setTextureInfo(metallicTexture, loader: loader)
                try roughness.setTextureInfo(metallicTexture, loader: loader)

                let image = try metalness.contents as? VRMImage ??? ._dataInconsistent("failed to load texture image")
                let (metalTexture, roughTexture) = try createMetallicRoughnessTexture(from: image)
                metalness.contents = metalTexture
                roughness.contents = roughTexture
            } else {
                metalness.contents = SKColor(white: CGFloat(pbr.metallicFactor), alpha: 1)
                roughness.contents = SKColor(white: CGFloat(pbr.roughnessFactor), alpha: 1)
            }
        }

        if let normalTexture = material.normalTexture {
            try normal.setTextureInfo(normalTexture, loader: loader)
        }

        if let occlusionTexture = material.occlusionTexture {
            try ambientOcclusion.setTextureInfo(occlusionTexture, loader: loader)
            ambientOcclusion.intensity = CGFloat(occlusionTexture.strength)
        }

        if let emissiveTexture = material.emissiveTexture {
            try emission.setTextureInfo(emissiveTexture, loader: loader)
        }

        if let mtoon {
            try applyMToon(mtoon, loader: loader)
        }
    }

    private func applyMToon(_ mtoon: MToonMaterialDescriptor, loader: VRMSceneLoader) throws {
        setMToonColor(mtoon.baseColorFactor, forKey: MToonUniform.baseColor)
        setMToonColor(mtoon.shadeColorFactor, forKey: MToonUniform.shadeColor)
        setMToonColor(mtoon.parametricRimColorFactor, forKey: MToonUniform.rimColor)
        setMToonColor(SIMD4<Float>(mtoon.matcapFactor.x, mtoon.matcapFactor.y, mtoon.matcapFactor.z, 1), forKey: MToonUniform.matcapColor)
        setMToonColor(mtoon.outlineColorFactor, forKey: MToonUniform.outlineColor)
        setValue(SCNVector4(mtoon.shadingShiftFactor,
                            mtoon.shadingToonyFactor,
                            mtoon.giEqualizationFactor,
                            mtoon.alphaCutoff),
                 forKey: MToonUniform.shadeParams)
        setValue(SCNVector4(mtoon.parametricRimFresnelPowerFactor,
                            mtoon.parametricRimLiftFactor,
                            mtoon.rimLightingMixFactor,
                            mtoon.outlineLightingMixFactor),
                 forKey: MToonUniform.rimParams)
        setValue(SCNVector4(mtoon.outlineWidthFactor,
                            mtoon.outlineWidthMode.rawValue,
                            mtoon.outlineLightingMixFactor,
                            mtoon.hasOutline ? 1 : 0),
                 forKey: MToonUniform.outlineParams)
        setValue(SCNVector4(mtoon.uvAnimationScrollXSpeedFactor,
                            mtoon.uvAnimationScrollYSpeedFactor,
                            mtoon.uvAnimationRotationSpeedFactor,
                            0),
                 forKey: MToonUniform.uvAnimation)
        setValue(SCNVector4(0.35, 0.55, 0.75, 0),
                 forKey: MToonUniform.lightDirection)

        if let baseColorTexture = mtoon.baseColorTexture {
            try setMToonTexture(baseColorTexture,
                                 to: diffuse,
                                 loader: loader,
                                 propertyName: "baseColorTexture")
        } else {
            diffuse.contents = SKColor(mtoon.baseColorFactor)
        }
        if let shadeTexture = mtoon.shadeMultiplyTexture {
            try setMToonTexture(shadeTexture,
                                 to: ambientOcclusion,
                                 loader: loader,
                                 propertyName: "shadeMultiplyTexture")
        }
        if let normalTexture = mtoon.normalTexture {
            try setMToonTexture(normalTexture,
                                 to: normal,
                                 loader: loader,
                                 propertyName: "normalTexture")
        }
        reflective.contents = SKColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let matcapTexture = mtoon.matcapTexture {
            try setMToonTexture(matcapTexture,
                                 to: reflective,
                                 loader: loader,
                                 propertyName: "matcapTexture")
        }
        selfIllumination.contents = SKColor(mtoon.parametricRimColorFactor)
        selfIllumination.intensity = CGFloat(mtoon.parametricRimLiftFactor)
        if let rimTexture = mtoon.rimMultiplyTexture {
            try setMToonTexture(rimTexture,
                                 to: selfIllumination,
                                 loader: loader,
                                 propertyName: "rimMultiplyTexture")
        }
        if let outlineWidthTexture = mtoon.outlineWidthMultiplyTexture {
            let property = SCNMaterialProperty()
            try setMToonTexture(outlineWidthTexture,
                                 to: property,
                                 loader: loader,
                                 propertyName: "outlineWidthMultiplyTexture")
            setValue(property, forKey: MToonUniform.outlineWidthMultiplyTexture)
        }
        if let uvMask = mtoon.uvAnimationMaskTexture {
            let property = SCNMaterialProperty()
            try setMToonTexture(uvMask,
                                 to: property,
                                 loader: loader,
                                 propertyName: "uvAnimationMaskTexture")
            setValue(property, forKey: MToonUniform.uvAnimationMaskTexture)
        }
        var modifiers: [SCNShaderModifierEntryPoint: String] = [
            .surface: MToonShaderModifier.surface
        ]
        if mtoon.uvAnimationScrollXSpeedFactor != 0 ||
            mtoon.uvAnimationScrollYSpeedFactor != 0 ||
            mtoon.uvAnimationRotationSpeedFactor != 0 {
            modifiers[.geometry] = mtoon.uvAnimationMaskTexture == nil
                ? MToonShaderModifier.geometry
                : MToonShaderModifier.geometryWithUvAnimationMask
        }
        shaderModifiers = modifiers

        if mtoon.alphaMode == .BLEND || mtoon.transparentWithZWrite {
            blendMode = .alpha
        }
        if mtoon.alphaMode == .MASK {
            transparencyMode = .aOne
        }
    }

    private func setMToonTexture(_ textureInfo: MToonMaterialDescriptor.Texture,
                                 to property: SCNMaterialProperty,
                                 loader: VRMSceneLoader,
                                 propertyName: String) throws {
        do {
            try property.setMToonTexture(textureInfo, loader: loader)
        } catch {
            let materialName = name ?? "<unnamed>"
            throw VRMError._dataInconsistent("Failed to load MToon \(propertyName) for material \(materialName): \(error)")
        }
    }

    private func createMetallicRoughnessTexture(from uiImage: VRMImage) throws -> (metal: VRMImage, rough: VRMImage) {
        let image = try uiImage.cgImage ??? ._dataInconsistent("failed to get cgImage")

        // https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#pbrmetallicroughnessmetallicroughnesstexture

        let pixelCount = image.width * image.height
        let bitsPerComponent = 8
        let componentsPerPixel = 4 // RGBA
        let srcBytesPerPixel = bitsPerComponent * componentsPerPixel / 8
        let srcDataSize = pixelCount * srcBytesPerPixel

        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: srcDataSize)
        let metalPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let roughPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        defer {
            ptr.deallocate()
            metalPtr.deallocate()
            roughPtr.deallocate()
        }

        let context = try CGContext(
            data: UnsafeMutableRawPointer(ptr),
            width: image.width,
            height: image.height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: srcBytesPerPixel * image.width,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ??? ._dataInconsistent("failed to create cgcontext")
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        for dstPos in 0..<pixelCount {
            let srcPos = dstPos * srcBytesPerPixel
            metalPtr[dstPos] = ptr[srcPos + 2] // blue
            roughPtr[dstPos] = ptr[srcPos + 1] // green
        }

        let metalImage = try createGraySpaceImage(width: image.width,
                                                  height: image.height,
                                                  dataPointer: metalPtr)

        let roughImage = try createGraySpaceImage(width: image.width,
                                                  height: image.height,
                                                  dataPointer: roughPtr)
        return (metalImage, roughImage)
    }

    private func createGraySpaceImage(width: Int,
                                      height: Int,
                                      dataPointer: UnsafeMutablePointer<UInt8>) throws -> VRMImage {
        let data = try CFDataCreate(nil, dataPointer, width * height) ??? ._dataInconsistent("failed to create CFDataCreate")
        let provider = try CGDataProvider(data: data) ??? ._dataInconsistent("failed to create CGDataProvider")
        let cgImage = try CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width * 1,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent) ??? ._dataInconsistent("failed to create CGImage")
        return VRMImage(cgImage: cgImage)
    }

    private func blendMode(of alphaMode: GLTF.Material.AlphaMode) -> SCNBlendMode {
        // FIXME/TODO: https://dwango.github.io/vrm/vrm_spec/#vrm%E3%81%8C%E6%8F%90%E4%BE%9B%E3%81%99%E3%82%8B%E3%82%B7%E3%82%A7%E3%83%BC%E3%83%80%E3%83%BC
        switch alphaMode {
        case .OPAQUE: return .replace
        case .BLEND: return .alpha // FIXME/TODO: blend shader
        case .MASK: return .alpha // FIXME/TODO: alphaCutoff shader
        }
    }
}

package enum MToonUniform {
    package static let baseColor = "mtoonBaseColorFactor"
    package static let shadeColor = "mtoonShadeColorFactor"
    package static let rimColor = "mtoonRimColorFactor"
    package static let matcapColor = "mtoonMatcapFactor"
    package static let outlineColor = "mtoonOutlineColorFactor"
    package static let shadeParams = "mtoonShadeParams"
    package static let rimParams = "mtoonRimParams"
    package static let outlineParams = "mtoonOutlineParams"
    package static let uvAnimation = "mtoonUvAnimation"
    package static let lightDirection = "mtoonLightDirection"
    package static let outlineWidthMultiplyTexture = "mtoonOutlineWidthMultiplyTexture"
    package static let uvAnimationMaskTexture = "mtoonUvAnimationMaskTexture"
}

private enum MToonShaderModifier {
    static let surface = """
    #pragma arguments
    float4 mtoonBaseColorFactor;
    float4 mtoonShadeColorFactor;
    float4 mtoonRimColorFactor;
    float4 mtoonMatcapFactor;
    float4 mtoonShadeParams;
    float4 mtoonRimParams;
    float4 mtoonLightDirection;
    #pragma body
    float3 mtoonNormal = normalize(_surface.normal);
    float3 mtoonResolvedLightDirection = normalize(mtoonLightDirection.xyz);
    float mtoonLambert = dot(mtoonNormal, mtoonResolvedLightDirection) * 0.5 + 0.5;
    float mtoonShift = clamp(mtoonShadeParams.x, -1.0, 1.0);
    float mtoonToony = clamp(mtoonShadeParams.y, 0.001, 0.999);
    float mtoonShade = smoothstep(mtoonShift, mtoonShift + max(0.001, 1.0 - mtoonToony), mtoonLambert);
    mtoonShade = mix(mtoonShade, 1.0, clamp(1.0 - mtoonShadeParams.z, 0.0, 1.0));
    if (mtoonShadeParams.w > 0.0 && _surface.diffuse.a < mtoonShadeParams.w) {
        discard_fragment();
    }
    float3 mtoonBaseColor = _surface.diffuse.rgb * mtoonBaseColorFactor.rgb;
    float3 mtoonShadeColor = float3(_surface.ambientOcclusion) * mtoonShadeColorFactor.rgb;
    _surface.diffuse.rgb = mix(mtoonShadeColor, mtoonBaseColor, mtoonShade);

    float mtoonViewDot = abs(dot(mtoonNormal, normalize(_surface.view)));
    float mtoonRim = pow(clamp(1.0 - mtoonViewDot + mtoonRimParams.y, 0.0, 1.0), max(mtoonRimParams.x, 0.001));
    _surface.emission.rgb += mtoonRimColorFactor.rgb * mtoonRim * mtoonRimParams.z;
    _surface.emission.rgb += _surface.reflective.rgb * mtoonMatcapFactor.rgb;

    """

    static let geometry = """
    #pragma arguments
    float4 mtoonUvAnimation;
    #pragma body
    float2 mtoonUV = _geometry.texcoords[0];
    float mtoonMask = 1.0;
    if (mtoonUvAnimation.x != 0.0 || mtoonUvAnimation.y != 0.0 || mtoonUvAnimation.z != 0.0) {
        float mtoonAngle = mtoonUvAnimation.z * mtoonUvAnimation.w * mtoonMask;
        float2 mtoonCenteredUV = mtoonUV - float2(0.5, 0.5);
        float mtoonSin = sin(mtoonAngle);
        float mtoonCos = cos(mtoonAngle);
        mtoonUV = float2(mtoonCenteredUV.x * mtoonCos - mtoonCenteredUV.y * mtoonSin,
                         mtoonCenteredUV.x * mtoonSin + mtoonCenteredUV.y * mtoonCos) + float2(0.5, 0.5);
        mtoonUV += mtoonUvAnimation.xy * mtoonUvAnimation.w * mtoonMask;
        _geometry.texcoords[0] = mtoonUV;
    }
    """

    static let geometryWithUvAnimationMask = """
    #pragma arguments
    float4 mtoonUvAnimation;
    texture2d<float> mtoonUvAnimationMaskTexture;
    sampler mtoonUvAnimationMaskTextureSampler;
    #pragma body
    float2 mtoonUV = _geometry.texcoords[0];
    float mtoonMask = 1.0;
    if (mtoonUvAnimation.x != 0.0 || mtoonUvAnimation.y != 0.0 || mtoonUvAnimation.z != 0.0) {
        mtoonMask = mtoonUvAnimationMaskTexture.sample(mtoonUvAnimationMaskTextureSampler, mtoonUV).b;
        float mtoonAngle = mtoonUvAnimation.z * mtoonUvAnimation.w * mtoonMask;
        float2 mtoonCenteredUV = mtoonUV - float2(0.5, 0.5);
        float mtoonSin = sin(mtoonAngle);
        float mtoonCos = cos(mtoonAngle);
        mtoonUV = float2(mtoonCenteredUV.x * mtoonCos - mtoonCenteredUV.y * mtoonSin,
                         mtoonCenteredUV.x * mtoonSin + mtoonCenteredUV.y * mtoonCos) + float2(0.5, 0.5);
        mtoonUV += mtoonUvAnimation.xy * mtoonUvAnimation.w * mtoonMask;
        _geometry.texcoords[0] = mtoonUV;
    }
    """

    static let outlineSurface = """
    #pragma arguments
    float4 mtoonOutlineColorFactor;
    float4 mtoonShadeParams;
    #pragma body
    if (mtoonShadeParams.w > 0.0 && mtoonOutlineColorFactor.a < mtoonShadeParams.w) {
        discard_fragment();
    }
    _surface.diffuse.rgb = mtoonOutlineColorFactor.rgb;
    _surface.emission.rgb = mtoonOutlineColorFactor.rgb;
    _surface.diffuse.a = mtoonOutlineColorFactor.a;
    """

    static let outlineGeometry = """
    #pragma arguments
    float4 mtoonOutlineParams;
    #pragma body
    if (mtoonOutlineParams.w > 0.5) {
        float mtoonOutlineWidth = max(0.0, mtoonOutlineParams.x);
        if (mtoonOutlineParams.y > 1.5) {
            mtoonOutlineWidth *= max(0.001, abs(_geometry.position.z)) * 0.002;
        }
        float3 mtoonOutlineNormal = _geometry.normal;
        float mtoonOutlineNormalLengthSquared = dot(mtoonOutlineNormal, mtoonOutlineNormal);
        if (mtoonOutlineNormalLengthSquared > 0.000001) {
            _geometry.position.xyz += mtoonOutlineNormal * rsqrt(mtoonOutlineNormalLengthSquared) * mtoonOutlineWidth;
        }
    }
    """

    static let outlineGeometryWithWidthTexture = """
    #pragma arguments
    float4 mtoonOutlineParams;
    texture2d<float> mtoonOutlineWidthMultiplyTexture;
    sampler mtoonOutlineWidthMultiplyTextureSampler;
    #pragma body
    if (mtoonOutlineParams.w > 0.5) {
        float mtoonOutlineWidth = max(0.0, mtoonOutlineParams.x);
        mtoonOutlineWidth *= mtoonOutlineWidthMultiplyTexture.sample(mtoonOutlineWidthMultiplyTextureSampler, _geometry.texcoords[0]).g;
        if (mtoonOutlineParams.y > 1.5) {
            mtoonOutlineWidth *= max(0.001, abs(_geometry.position.z)) * 0.002;
        }
        float3 mtoonOutlineNormal = _geometry.normal;
        float mtoonOutlineNormalLengthSquared = dot(mtoonOutlineNormal, mtoonOutlineNormal);
        if (mtoonOutlineNormalLengthSquared > 0.000001) {
            _geometry.position.xyz += mtoonOutlineNormal * rsqrt(mtoonOutlineNormalLengthSquared) * mtoonOutlineWidth;
        }
    }
    """
}

package extension SCNMaterial {
    func setMToonColor(_ color: SIMD4<Float>, forKey key: String) {
        setValue(SCNVector4(color.x, color.y, color.z, color.w), forKey: key)
    }

    func mtoonColor(forKey key: String) -> SIMD4<Float>? {
        guard let vector = value(forKey: key) as? SCNVector4 else { return nil }
        return SIMD4<Float>(Float(vector.x), Float(vector.y), Float(vector.z), Float(vector.w))
    }

    func mtoonOutlineMaterial() -> SCNMaterial? {
        guard let outlineParams = value(forKey: MToonUniform.outlineParams) as? SCNVector4,
              outlineParams.w > 0.5 else {
            return nil
        }
        let material = SCNMaterial()
        material.name = name.map { "\($0)_outline" }
        material.lightingModel = .constant
        material.isLitPerPixel = false
        material.isDoubleSided = false
        material.cullMode = .front
        material.blendMode = blendMode
        material.transparencyMode = transparencyMode
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        if let outlineColor = value(forKey: MToonUniform.outlineColor) {
            material.setValue(outlineColor, forKey: MToonUniform.outlineColor)
        }
        if let shadeParams = value(forKey: MToonUniform.shadeParams) {
            material.setValue(shadeParams, forKey: MToonUniform.shadeParams)
        }
        material.setValue(outlineParams, forKey: MToonUniform.outlineParams)
        let outlineWidthTexture = value(forKey: MToonUniform.outlineWidthMultiplyTexture)
        if let outlineWidthTexture {
            material.setValue(outlineWidthTexture, forKey: MToonUniform.outlineWidthMultiplyTexture)
        }
        material.shaderModifiers = [
            .surface: MToonShaderModifier.outlineSurface,
            .geometry: outlineWidthTexture == nil
                ? MToonShaderModifier.outlineGeometry
                : MToonShaderModifier.outlineGeometryWithWidthTexture
        ]
        return material
    }
}

private extension SKColor {
    convenience init(_ color: SIMD4<Float>) {
        self.init(red: CGFloat(color.x),
                  green: CGFloat(color.y),
                  blue: CGFloat(color.z),
                  alpha: CGFloat(color.w))
    }
}
