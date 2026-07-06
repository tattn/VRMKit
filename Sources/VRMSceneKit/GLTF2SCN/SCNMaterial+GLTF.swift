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
        let mtoon = loader.isMToonEnabled
            ? MToonMaterialDescriptor(material: material, materialProperty: materialProperty)
            : nil
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

        if let emissiveTexture = material.emissiveTexture, !isMToon {
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
        setValue(SCNVector4(mtoon.emissiveFactor.x,
                            mtoon.emissiveFactor.y,
                            mtoon.emissiveFactor.z,
                            1),
                 forKey: MToonUniform.emissiveColor)
        setValue(SCNVector4(mtoon.shadingShiftFactor,
                            mtoon.shadingToonyFactor,
                            mtoon.giEqualizationFactor,
                            0),
                 forKey: MToonUniform.shadeParams)
        setValue(SCNVector4(mtoon.parametricRimFresnelPowerFactor,
                            mtoon.parametricRimLiftFactor,
                            mtoon.rimLightingMixFactor,
                            0),
                 forKey: MToonUniform.rimParams)
        setValue(SCNVector4(mtoon.outlineWidthFactor,
                            mtoon.outlineWidthMode.rawValue,
                            mtoon.outlineLightingMixFactor,
                            mtoon.hasOutline ? 1 : 0),
                 forKey: MToonUniform.outlineParams)
        setValue(SCNVector4(mtoon.uvAnimationScrollXSpeedFactor,
                            mtoon.uvAnimationScrollYSpeedFactor,
                            mtoon.uvAnimationRotationSpeedFactor,
                            mtoon.shadingShiftTextureScale),
                 forKey: MToonUniform.uvAnimation)
        setValue(SCNVector4(mtoon.alphaMode.mtoonRawValue,
                            mtoon.alphaCutoff,
                            mtoon.shadeMultiplyTexture == nil ? 0 : 1,
                            0),
                 forKey: MToonUniform.alphaParams)
        // Optional-texture flags gate contribution, while 1x1 fallback images keep
        // SceneKit's texture2d shader arguments bound even when the source texture is absent.
        setValue(SCNVector4(mtoon.matcapTexture == nil ? 0 : 1,
                            mtoon.rimMultiplyTexture == nil ? 0 : 1,
                            mtoon.shadingShiftTexture == nil ? 0 : 1,
                            mtoon.emissiveTexture == nil ? 0 : 1),
                 forKey: MToonUniform.featureParams)
        setValue(SCNVector4(0.35, 0.55, 0.75, 0),
                 forKey: MToonUniform.lightDirection)
        setValue(SCNVector4(1, 1, 1, 1),
                 forKey: MToonUniform.lightColor)
        setValue(SCNVector4(0, 0, 0, 1),
                 forKey: MToonUniform.ambientColor)

        if let baseColorTexture = mtoon.baseColorTexture {
            try setMToonTexture(baseColorTexture,
                                 to: diffuse,
                                 loader: loader,
                                 propertyName: "baseColorTexture")
        } else {
            diffuse.contents = SKColor(white: 1, alpha: 1)
        }
        if let shadeTexture = mtoon.shadeMultiplyTexture {
            let property = SCNMaterialProperty()
            try setMToonTexture(shadeTexture,
                                to: property,
                                loader: loader,
                                propertyName: "shadeMultiplyTexture")
            setValue(property, forKey: MToonUniform.shadeMultiplyTexture)
        } else {
            setValue(try createMToonFallbackTexture(red: 255, green: 255, blue: 255),
                     forKey: MToonUniform.shadeMultiplyTexture)
        }
        if let shadingShiftTexture = mtoon.shadingShiftTexture {
            let property = SCNMaterialProperty()
            try setMToonTexture(shadingShiftTexture,
                                to: property,
                                loader: loader,
                                propertyName: "shadingShiftTexture")
            setValue(property, forKey: MToonUniform.shadingShiftTexture)
        } else {
            setValue(try createMToonFallbackTexture(red: 0, green: 0, blue: 0),
                     forKey: MToonUniform.shadingShiftTexture)
        }
        if let normalTexture = mtoon.normalTexture {
            try setMToonTexture(normalTexture,
                                 to: normal,
                                 loader: loader,
                                 propertyName: "normalTexture")
        }
        if let matcapTexture = mtoon.matcapTexture {
            let property = SCNMaterialProperty()
            try setMToonTexture(matcapTexture,
                                to: property,
                                loader: loader,
                                propertyName: "matcapTexture")
            setValue(property, forKey: MToonUniform.matcapTexture)
        } else {
            setValue(try createMToonFallbackTexture(red: 0, green: 0, blue: 0),
                     forKey: MToonUniform.matcapTexture)
        }
        if let rimTexture = mtoon.rimMultiplyTexture {
            let property = SCNMaterialProperty()
            try setMToonTexture(rimTexture,
                                to: property,
                                loader: loader,
                                propertyName: "rimMultiplyTexture")
            setValue(property, forKey: MToonUniform.rimMultiplyTexture)
        } else {
            setValue(try createMToonFallbackTexture(red: 255, green: 255, blue: 255),
                     forKey: MToonUniform.rimMultiplyTexture)
        }
        if let emissiveTexture = mtoon.emissiveTexture {
            let property = SCNMaterialProperty()
            try setMToonTexture(emissiveTexture,
                                to: property,
                                loader: loader,
                                propertyName: "emissiveTexture")
            setValue(property, forKey: MToonUniform.emissiveTexture)
        } else {
            setValue(try createMToonFallbackTexture(red: 255, green: 255, blue: 255),
                     forKey: MToonUniform.emissiveTexture)
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

    private func createMToonFallbackTexture(red: UInt8,
                                            green: UInt8,
                                            blue: UInt8,
                                            alpha: UInt8 = 255) throws -> SCNMaterialProperty {
        let property = SCNMaterialProperty()
        property.contents = try createColorImage(red: red, green: green, blue: blue, alpha: alpha)
        property.magnificationFilter = .nearest
        property.minificationFilter = .nearest
        property.mipFilter = .none
        property.wrapS = .repeat
        property.wrapT = .repeat
        return property
    }

    private func createColorImage(red: UInt8,
                                  green: UInt8,
                                  blue: UInt8,
                                  alpha: UInt8) throws -> VRMImage {
        let bytes = [red, green, blue, alpha]
        let data = try bytes.withUnsafeBufferPointer {
            try CFDataCreate(nil, $0.baseAddress, $0.count) ??? ._dataInconsistent("failed to create CFDataCreate")
        }
        let provider = try CGDataProvider(data: data) ??? ._dataInconsistent("failed to create CGDataProvider")
        let cgImage = try CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
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

private extension GLTF.Material.AlphaMode {
    var mtoonRawValue: Float {
        switch self {
        case .OPAQUE: return 0
        case .MASK: return 1
        case .BLEND: return 2
        }
    }
}

package enum MToonUniform {
    package static let baseColor = "mtoonBaseColorFactor"
    package static let shadeColor = "mtoonShadeColorFactor"
    package static let rimColor = "mtoonRimColorFactor"
    package static let matcapColor = "mtoonMatcapFactor"
    package static let outlineColor = "mtoonOutlineColorFactor"
    package static let emissiveColor = "mtoonEmissiveFactor"
    package static let shadeParams = "mtoonShadeParams"
    package static let rimParams = "mtoonRimParams"
    package static let outlineParams = "mtoonOutlineParams"
    package static let uvAnimation = "mtoonUvAnimation"
    package static let alphaParams = "mtoonAlphaParams"
    package static let featureParams = "mtoonFeatureParams"
    package static let lightDirection = "mtoonLightDirection"
    package static let lightColor = "mtoonLightColor"
    package static let ambientColor = "mtoonAmbientColor"
    package static let shadeMultiplyTexture = "mtoonShadeMultiplyTexture"
    package static let shadingShiftTexture = "mtoonShadingShiftTexture"
    package static let matcapTexture = "mtoonMatcapTexture"
    package static let rimMultiplyTexture = "mtoonRimMultiplyTexture"
    package static let emissiveTexture = "mtoonEmissiveTexture"
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
    float4 mtoonEmissiveFactor;
    float4 mtoonShadeParams;
    float4 mtoonRimParams;
    float4 mtoonUvAnimation;
    float4 mtoonAlphaParams;
    float4 mtoonFeatureParams;
    float4 mtoonLightDirection;
    float4 mtoonLightColor;
    float4 mtoonAmbientColor;
    texture2d<float> mtoonShadeMultiplyTexture;
    sampler mtoonShadeMultiplyTextureSampler;
    texture2d<float> mtoonShadingShiftTexture;
    sampler mtoonShadingShiftTextureSampler;
    texture2d<float> mtoonMatcapTexture;
    sampler mtoonMatcapTextureSampler;
    texture2d<float> mtoonRimMultiplyTexture;
    sampler mtoonRimMultiplyTextureSampler;
    texture2d<float> mtoonEmissiveTexture;
    sampler mtoonEmissiveTextureSampler;
    #pragma body
    const float mtoonEPS = 0.00001;
    float3 mtoonNormal = normalize(_surface.normal);
    float3 mtoonResolvedLightDirection = normalize(mtoonLightDirection.xyz);
    float3 mtoonView = normalize(_surface.view);
    float2 mtoonUV = _surface.diffuseTexcoord;
    float4 mtoonBaseSample = _surface.diffuse;
    float mtoonAlpha = mtoonBaseSample.a * mtoonBaseColorFactor.a;
    if (mtoonAlphaParams.x > 0.5 && mtoonAlphaParams.x < 1.5) {
        if (mtoonAlpha < mtoonAlphaParams.y) {
            discard_fragment();
        }
        _surface.diffuse.a = 1.0;
    } else if (mtoonAlphaParams.x > 1.5) {
        _surface.diffuse.a = mtoonAlpha;
    } else {
        _surface.diffuse.a = 1.0;
    }

    float3 mtoonLitColor = mtoonBaseColorFactor.rgb * mtoonBaseSample.rgb;
    float3 mtoonShadeColor = mtoonShadeColorFactor.rgb;
    if (mtoonAlphaParams.z > 0.5) {
        mtoonShadeColor *= mtoonShadeMultiplyTexture.sample(mtoonShadeMultiplyTextureSampler, mtoonUV).rgb;
    }
    float mtoonShift = mtoonShadeParams.x;
    if (mtoonFeatureParams.z > 0.5) {
        mtoonShift += mtoonShadingShiftTexture.sample(mtoonShadingShiftTextureSampler, mtoonUV).r * mtoonUvAnimation.w;
    }
    float mtoonToony = clamp(mtoonShadeParams.y, 0.0, 1.0);
    float mtoonLinearstepA = -1.0 + mtoonToony;
    float mtoonLinearstepB = 1.0 - mtoonToony;
    float mtoonShading = clamp((dot(mtoonNormal, mtoonResolvedLightDirection) + mtoonShift - mtoonLinearstepA) / max(mtoonLinearstepB - mtoonLinearstepA, mtoonEPS), 0.0, 1.0);
    float3 mtoonDirect = mix(mtoonShadeColor, mtoonLitColor, mtoonShading) * mtoonLightColor.rgb;
    // SceneKit does not expose UniVRM's full GI pipeline; use the explicit MToon ambient color as the controllable approximation.
    float3 mtoonAmbient = mtoonAmbientColor.rgb;
    float mtoonAmbientLuma = dot(mtoonAmbient, float3(0.2126, 0.7152, 0.0722));
    mtoonAmbient = mix(mtoonAmbient, float3(mtoonAmbientLuma), clamp(mtoonShadeParams.z, 0.0, 1.0));
    float3 mtoonIndirect = mtoonLitColor * mtoonAmbient;
    float3 mtoonSurfaceColor = mtoonDirect + mtoonIndirect;

    float3 mtoonRim = float3(0.0);
    if (mtoonFeatureParams.x > 0.5) {
        float2 mtoonMatcapUV = mtoonNormal.xy * float2(0.5, -0.5) + float2(0.5, 0.5);
        mtoonRim = mtoonMatcapFactor.rgb * mtoonMatcapTexture.sample(mtoonMatcapTextureSampler, mtoonMatcapUV).rgb;
    }
    float mtoonViewDot = saturate(dot(mtoonNormal, mtoonView));
    float mtoonParametricRim = pow(saturate(1.0 - mtoonViewDot + mtoonRimParams.y), max(mtoonRimParams.x, mtoonEPS));
    mtoonRim += mtoonParametricRim * mtoonRimColorFactor.rgb;
    if (mtoonFeatureParams.y > 0.5) {
        mtoonRim *= mtoonRimMultiplyTexture.sample(mtoonRimMultiplyTextureSampler, mtoonUV).rgb;
    }
    mtoonRim *= mix(float3(1.0), mtoonSurfaceColor, clamp(mtoonRimParams.z, 0.0, 1.0));

    float3 mtoonEmissive = mtoonEmissiveFactor.rgb;
    if (mtoonFeatureParams.w > 0.5) {
        mtoonEmissive *= mtoonEmissiveTexture.sample(mtoonEmissiveTextureSampler, mtoonUV).rgb;
    }
    _surface.diffuse.rgb = mtoonSurfaceColor;
    _surface.emission.rgb += mtoonRim;
    _surface.emission.rgb += mtoonEmissive;

    """

    static let geometry = """
    #pragma arguments
    float4 mtoonUvAnimation;
    #pragma body
    float2 mtoonUV = _geometry.texcoords[0];
    float mtoonMask = 1.0;
    if (mtoonUvAnimation.x != 0.0 || mtoonUvAnimation.y != 0.0 || mtoonUvAnimation.z != 0.0) {
        float mtoonAngle = mtoonUvAnimation.z * u_time * mtoonMask;
        float2 mtoonCenteredUV = mtoonUV - float2(0.5, 0.5);
        float mtoonSin = sin(mtoonAngle);
        float mtoonCos = cos(mtoonAngle);
        mtoonUV = float2(mtoonCenteredUV.x * mtoonCos - mtoonCenteredUV.y * mtoonSin,
                         mtoonCenteredUV.x * mtoonSin + mtoonCenteredUV.y * mtoonCos) + float2(0.5, 0.5);
        mtoonUV += mtoonUvAnimation.xy * u_time * mtoonMask;
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
        float mtoonAngle = mtoonUvAnimation.z * u_time * mtoonMask;
        float2 mtoonCenteredUV = mtoonUV - float2(0.5, 0.5);
        float mtoonSin = sin(mtoonAngle);
        float mtoonCos = cos(mtoonAngle);
        mtoonUV = float2(mtoonCenteredUV.x * mtoonCos - mtoonCenteredUV.y * mtoonSin,
                         mtoonCenteredUV.x * mtoonSin + mtoonCenteredUV.y * mtoonCos) + float2(0.5, 0.5);
        mtoonUV += mtoonUvAnimation.xy * u_time * mtoonMask;
        _geometry.texcoords[0] = mtoonUV;
    }
    """

    static let outlineSurface = """
    #pragma arguments
    float4 mtoonBaseColorFactor;
    float4 mtoonShadeColorFactor;
    float4 mtoonOutlineColorFactor;
    float4 mtoonShadeParams;
    float4 mtoonOutlineParams;
    float4 mtoonAlphaParams;
    float4 mtoonLightDirection;
    float4 mtoonLightColor;
    float4 mtoonAmbientColor;
    #pragma body
    const float mtoonEPS = 0.00001;
    float mtoonOutlineAlpha = _surface.diffuse.a * mtoonBaseColorFactor.a;
    if (mtoonAlphaParams.x > 0.5 && mtoonAlphaParams.x < 1.5) {
        if (mtoonOutlineAlpha < mtoonAlphaParams.y) {
            discard_fragment();
        }
        _surface.diffuse.a = 1.0;
    } else if (mtoonAlphaParams.x > 1.5) {
        _surface.diffuse.a = mtoonOutlineAlpha;
    } else {
        _surface.diffuse.a = 1.0;
    }

    float3 mtoonNormal = normalize(_surface.normal);
    float3 mtoonResolvedLightDirection = normalize(mtoonLightDirection.xyz);
    float mtoonToony = clamp(mtoonShadeParams.y, 0.0, 1.0);
    float mtoonLinearstepA = -1.0 + mtoonToony;
    float mtoonLinearstepB = 1.0 - mtoonToony;
    float mtoonShading = clamp((dot(mtoonNormal, mtoonResolvedLightDirection) + mtoonShadeParams.x - mtoonLinearstepA) / max(mtoonLinearstepB - mtoonLinearstepA, mtoonEPS), 0.0, 1.0);
    float3 mtoonDirect = mix(mtoonShadeColorFactor.rgb, mtoonBaseColorFactor.rgb, mtoonShading) * mtoonLightColor.rgb;
    float3 mtoonAmbient = mtoonAmbientColor.rgb;
    float mtoonAmbientLuma = dot(mtoonAmbient, float3(0.2126, 0.7152, 0.0722));
    mtoonAmbient = mix(mtoonAmbient, float3(mtoonAmbientLuma), clamp(mtoonShadeParams.z, 0.0, 1.0));
    float3 mtoonLit = mtoonDirect + mtoonBaseColorFactor.rgb * mtoonAmbient;
    float3 mtoonOutlineColor = mtoonOutlineColorFactor.rgb * mix(float3(1.0), mtoonLit, clamp(mtoonOutlineParams.z, 0.0, 1.0));
    _surface.diffuse.rgb = mtoonOutlineColor;
    _surface.emission.rgb = mtoonOutlineColor;
    """

    static let outlineGeometry = """
    #pragma arguments
    float4 mtoonOutlineParams;
    #pragma body
    if (mtoonOutlineParams.w > 0.5) {
        float mtoonOutlineWidth = max(0.0, mtoonOutlineParams.x);
        if (mtoonOutlineParams.y > 1.5) {
            // screenCoordinates: the width factor is relative to the screen height.
            // Convert it to view-space units at this depth using the projection matrix
            // (frustum height at depth d is 2 * d / P[1][1]).
            // Note: only scn_node / scn_frame members are valid in Metal shader modifiers.
            float mtoonViewDepth = max(0.001, abs((scn_node.modelViewTransform * float4(_geometry.position.xyz, 1.0)).z));
            mtoonOutlineWidth *= mtoonViewDepth * 2.0 / max(0.001, scn_frame.projectionTransform[1][1]);
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
            // screenCoordinates: the width factor is relative to the screen height.
            // Convert it to view-space units at this depth using the projection matrix
            // (frustum height at depth d is 2 * d / P[1][1]).
            // Note: only scn_node / scn_frame members are valid in Metal shader modifiers.
            float mtoonViewDepth = max(0.001, abs((scn_node.modelViewTransform * float4(_geometry.position.xyz, 1.0)).z));
            mtoonOutlineWidth *= mtoonViewDepth * 2.0 / max(0.001, scn_frame.projectionTransform[1][1]);
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
        material.copyTextureState(from: diffuse, to: material.diffuse)
        for key in [
            MToonUniform.baseColor,
            MToonUniform.shadeColor,
            MToonUniform.outlineColor,
            MToonUniform.shadeParams,
            MToonUniform.outlineParams,
            MToonUniform.alphaParams,
            MToonUniform.lightDirection,
            MToonUniform.lightColor,
            MToonUniform.ambientColor
        ] {
            if let value = value(forKey: key) {
                material.setValue(value, forKey: key)
            }
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

    private func copyTextureState(from source: SCNMaterialProperty, to destination: SCNMaterialProperty) {
        destination.contents = source.contents
        destination.contentsTransform = source.contentsTransform
        destination.magnificationFilter = source.magnificationFilter
        destination.minificationFilter = source.minificationFilter
        destination.mipFilter = source.mipFilter
        destination.wrapS = source.wrapS
        destination.wrapT = source.wrapT
        destination.mappingChannel = source.mappingChannel
        destination.intensity = source.intensity
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
