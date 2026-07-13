#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct MToonMaterialParametersComponent: Component {
    var parameters: MToonMaterialParameters
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct MToonMaterialParameters {
    static let defaultLightDirection = simd_normalize(SIMD3<Float>(0.35, 0.55, 0.75))
    static let baseParameterRowCount = 17
    static let samplerRowCount = MToonTextureSlot.allCases.count
    static let textureRowCount = baseParameterRowCount + samplerRowCount
    static let defaultSampler = SIMD4<Float>(0, 0, 0, 0)

    var baseColor: SIMD4<Float>
    var shadeColor: SIMD4<Float>
    var rimColor: SIMD4<Float>
    var matcapColor: SIMD4<Float>
    var outlineColor: SIMD4<Float>
    var shadeParams: SIMD4<Float>
    var rimParams: SIMD4<Float>
    var outlineParams: SIMD4<Float>
    var uvAnimation: SIMD4<Float>
    var featureFlags: SIMD4<Float>
    var extraFlags: SIMD4<Float>
    var emissiveFactor: SIMD4<Float>
    var lightColor = SIMD4<Float>(1, 1, 1, 1)
    var ambientColor = SIMD4<Float>(0, 0, 0, 1)
    var uvTransform = SIMD4<Float>(1, 1, 0, 0)
    var uvTransformRotation = SIMD4<Float>(1, 0, 0, 0)
    var normalParameters: SIMD4<Float>
    var samplers = Array(repeating: MToonMaterialParameters.defaultSampler,
                         count: MToonMaterialParameters.samplerRowCount)
    var lightDirection: SIMD3<Float> = MToonMaterialParameters.defaultLightDirection
    var elapsedTime: Float = 0

    init(_ mtoon: MToonMaterialDescriptor) {
        baseColor = mtoon.baseColorFactor
        shadeColor = mtoon.shadeColorFactor
        rimColor = mtoon.parametricRimColorFactor
        matcapColor = SIMD4<Float>(mtoon.matcapFactor.x, mtoon.matcapFactor.y, mtoon.matcapFactor.z, 1)
        outlineColor = mtoon.outlineColorFactor
        emissiveFactor = SIMD4<Float>(mtoon.emissiveFactor.x, mtoon.emissiveFactor.y, mtoon.emissiveFactor.z, 1)
        shadeParams = SIMD4<Float>(mtoon.shadingShiftFactor,
                                   mtoon.shadingToonyFactor,
                                   mtoon.giEqualizationFactor,
                                   mtoon.alphaCutoff)
        rimParams = SIMD4<Float>(mtoon.parametricRimFresnelPowerFactor,
                                 mtoon.parametricRimLiftFactor,
                                 mtoon.rimLightingMixFactor,
                                 0)
        outlineParams = SIMD4<Float>(mtoon.outlineWidthFactor,
                                     mtoon.outlineWidthMode.rawValue,
                                     mtoon.outlineLightingMixFactor,
                                     mtoon.hasOutline ? 1 : 0)
        uvAnimation = SIMD4<Float>(mtoon.uvAnimationScrollXSpeedFactor,
                                   mtoon.uvAnimationScrollYSpeedFactor,
                                   mtoon.uvAnimationRotationSpeedFactor,
                                   mtoon.shadingShiftTextureScale)
        featureFlags = SIMD4<Float>(mtoon.matcapTexture == nil ? 0 : 1,
                                    mtoon.rimMultiplyTexture == nil ? 0 : 1,
                                    mtoon.shadingShiftTexture == nil ? 0 : 1,
                                    mtoon.uvAnimationMaskTexture == nil ? 0 : 1)
        extraFlags = SIMD4<Float>(mtoon.normalTexture == nil ? 0 : 1,
                                  mtoon.shadeMultiplyTexture == nil ? 0 : 1,
                                  mtoon.emissiveTexture == nil ? 0 : 1,
                                  mtoon.alphaMode.mtoonRawValue)
        normalParameters = SIMD4<Float>(mtoon.normalScale, 0, 0, 0)
    }

    var customValue: SIMD4<Float> {
        SIMD4<Float>(lightDirection.x, lightDirection.y, lightDirection.z, elapsedTime)
    }

    mutating func setColor(_ color: SIMD4<Float>,
                           for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Bool {
        switch type {
        case .color:
            baseColor = color
        case .shadeColor:
            shadeColor = color
        case .matcapColor:
            matcapColor = color
        case .rimColor:
            rimColor = color
        case .outlineColor:
            outlineColor = color
        case .emissionColor:
            emissiveFactor = SIMD4<Float>(color.x, color.y, color.z, emissiveFactor.w)
        }
        return true
    }

    func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float>? {
        switch type {
        case .color:
            return baseColor
        case .shadeColor:
            return shadeColor
        case .matcapColor:
            return matcapColor
        case .rimColor:
            return rimColor
        case .outlineColor:
            return outlineColor
        case .emissionColor:
            return emissiveFactor
        }
    }

    mutating func setTextureTransform(scale: SIMD2<Float>,
                                      offset: SIMD2<Float>,
                                      rotation: Float) {
        uvTransform = SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)
        uvTransformRotation = SIMD4<Float>(cos(rotation), sin(rotation), 0, 0)
    }

    mutating func setSampler(_ sampler: SIMD4<Float>, for slot: MToonTextureSlot) {
        samplers[slot.rawValue] = sampler
    }

    @MainActor
    func textureResource() throws -> TextureResource {
        let rows = [
            baseColor,
            shadeColor,
            rimColor,
            matcapColor,
            outlineColor,
            shadeParams,
            rimParams,
            outlineParams,
            uvAnimation,
            featureFlags,
            extraFlags,
            emissiveFactor,
            lightColor,
            ambientColor,
            uvTransform,
            uvTransformRotation,
            normalParameters
        ] + samplers
        precondition(rows.count == Self.textureRowCount)
        let data = rows.withUnsafeBufferPointer { Data(buffer: $0) }
        let mip = TextureResource.Contents.MipmapLevel.mip(
            data: data,
            bytesPerRow: MemoryLayout<SIMD4<Float>>.stride * rows.count
        )
        return try TextureResource(dimensions: .dimensions(width: rows.count, height: 1),
                                   format: .raw(pixelFormat: .rgba32Float),
                                   contents: .init(mipmapLevels: [mip]))
    }
}

enum MToonTextureSlot: Int, CaseIterable {
    case base
    case shade
    case shadingShift
    case normal
    case matcap
    case emissive
    case rim
    case outlineWidth
    case uvAnimationMask

    var semantic: TextureResource.Semantic {
        switch self {
        case .shadingShift, .outlineWidth, .uvAnimationMask:
            return .raw
        case .normal:
            return .normal
        case .base, .shade, .matcap, .emissive, .rim:
            return .color
        }
    }
}

private extension GLTF.Material.AlphaMode {
    var mtoonRawValue: Float {
        switch self {
        case .OPAQUE:
            return 0
        case .MASK:
            return 1
        case .BLEND:
            return 2
        }
    }
}

#endif
