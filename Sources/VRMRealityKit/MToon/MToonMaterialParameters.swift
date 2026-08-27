#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

/// Rows of the MToon parameter texture, in the order the shader indexes them.
/// This enum is the single source of truth for the layout: `MToon.metal`
/// mirrors it as `mtoonRow*` constants, and a test compares the two.
enum MToonParameterRow: Int, CaseIterable {
    case baseColor
    case shadeColor
    case rimColor
    case matcapColor
    case outlineColor
    case shadeParams
    case rimParams
    case outlineParams
    case uvAnimation
    case featureFlags
    case extraFlags
    case emissiveFactor
    case lightColor
    case ambientColor
    case uvTransform
    case uvTransformRotation
    case normalParameters
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct MToonMaterialParameters {
    static let defaultLightDirection = simd_normalize(SIMD3<Float>(0.35, 0.55, 0.75))
    static let baseParameterRowCount = MToonParameterRow.allCases.count
    static let samplerRowCount = MToonTextureSlot.allCases.count
    static let textureRowCount = baseParameterRowCount + samplerRowCount
    /// The glTF default sampler: REPEAT on both axes, linear magnification,
    /// trilinear minification.
    static let defaultSampler = SIMD4<Float>(0, 0, Float(MToonSamplerFilter.default.index), 0)

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

    init(_ mtoon: MToonMaterialDescriptor) {
        baseColor = mtoon.baseColorFactor
        shadeColor = mtoon.shadeColorFactor
        rimColor = mtoon.parametricRimColorFactor
        matcapColor = SIMD4<Float>(mtoon.matcapFactor, 1)
        outlineColor = mtoon.outlineColorFactor
        emissiveFactor = SIMD4<Float>(mtoon.emissiveFactor, 1)
        // z keeps the rows a faithful copy of the material; the shader has no use
        // for giEqualizationFactor, since VRMEntity exposes one uniform ambient
        // color rather than a direction dependent term.
        shadeParams = SIMD4<Float>(mtoon.shadingShiftFactor,
                                   mtoon.shadingToonyFactor,
                                   mtoon.giEqualizationFactor,
                                   mtoon.alphaCutoff)
        rimParams = SIMD4<Float>(mtoon.parametricRimFresnelPowerFactor,
                                 mtoon.parametricRimLiftFactor,
                                 mtoon.rimLightingMixFactor,
                                 0)
        // w flags an outlineWidthMultiplyTexture so the outline geometry
        // modifier can skip its mask sample when there is none.
        outlineParams = SIMD4<Float>(mtoon.outlineWidthFactor,
                                     mtoon.outlineWidthMode.mtoonRawValue,
                                     mtoon.outlineLightingMixFactor,
                                     mtoon.outlineWidthMultiplyTexture == nil ? 0 : 1)
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

    /// What does not belong in the packed texture: the light direction, which
    /// moves too often to rebake rows for, and the outline budget, which belongs
    /// to the mesh a pass draws rather than to the material.
    func customValue(outlineBudget: Float) -> SIMD4<Float> {
        SIMD4<Float>(lightDirection, outlineBudget)
    }

    mutating func setColor(_ color: SIMD4<Float>,
                           for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) {
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
    }

    func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float> {
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

    /// Leaves the lighting mix (z) and the width-texture flag (w) the material
    /// was authored with, so an override keeps sampling the authored mask.
    mutating func setOutline(width: Float, mode: MToonMaterialDescriptor.OutlineWidthMode) {
        outlineParams.x = width
        outlineParams.y = mode.mtoonRawValue
    }

    mutating func setTextureTransform(scale: SIMD2<Float>,
                                      offset: SIMD2<Float>,
                                      rotation: Float) {
        uvTransform = SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)
        uvTransformRotation = SIMD4<Float>(cos(rotation), sin(rotation), 0, 0)
    }

    /// The UV transform the shader currently applies. MToon materials own it in
    /// the parameter rows rather than in `CustomMaterial.textureCoordinateTransform`.
    var textureTransform: MaterialParameterTypes.TextureCoordinateTransform {
        MaterialParameterTypes.TextureCoordinateTransform(
            offset: SIMD2<Float>(uvTransform.z, uvTransform.w),
            scale: SIMD2<Float>(uvTransform.x, uvTransform.y),
            rotation: atan2(uvTransformRotation.y, uvTransformRotation.x)
        )
    }

    mutating func setSampler(_ sampler: SIMD4<Float>, for slot: MToonTextureSlot) {
        samplers[slot.rawValue] = sampler
    }

    func value(for row: MToonParameterRow) -> SIMD4<Float> {
        switch row {
        case .baseColor: return baseColor
        case .shadeColor: return shadeColor
        case .rimColor: return rimColor
        case .matcapColor: return matcapColor
        case .outlineColor: return outlineColor
        case .shadeParams: return shadeParams
        case .rimParams: return rimParams
        case .outlineParams: return outlineParams
        case .uvAnimation: return uvAnimation
        case .featureFlags: return featureFlags
        case .extraFlags: return extraFlags
        case .emissiveFactor: return emissiveFactor
        case .lightColor: return lightColor
        case .ambientColor: return ambientColor
        case .uvTransform: return uvTransform
        case .uvTransformRotation: return uvTransformRotation
        case .normalParameters: return normalParameters
        }
    }

    /// The rows as the shader indexes them: the base rows in
    /// ``MToonParameterRow`` order, then the sampler rows at
    /// `MToonTextureSlot.rawValue`.
    var packedRows: [SIMD4<Float>] {
        let rows = MToonParameterRow.allCases.map(value(for:)) + samplers
        precondition(rows.count == Self.textureRowCount)
        return rows
    }

    @MainActor
    func textureResource() throws -> TextureResource {
        let rows = packedRows
        let data = rows.withUnsafeBufferPointer { Data(buffer: $0) }
        let mip = TextureResource.Contents.MipmapLevel.mip(
            data: data,
            bytesPerRow: MToonParameterTexture.bytesPerRow
        )
        return try TextureResource(dimensions: .dimensions(width: rows.count, height: 1),
                                   format: .raw(pixelFormat: .rgba32Float),
                                   contents: .init(mipmapLevels: [mip]))
    }
}

/// One material's packed parameter rows as a texture the rows are written into
/// in place.
///
/// The rows move on per-frame paths, so the resource is allocated once and every
/// later write is a blit into it: the materials keep sampling the same
/// ``resource``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class MToonParameterTexture {
    static let bytesPerRow = MemoryLayout<SIMD4<Float>>.stride * MToonMaterialParameters.textureRowCount

    /// What the materials sample. It outlives every write, so installing it on
    /// a material once is enough.
    let resource: TextureResource

    private let texture: LowLevelTexture
    private let commandQueue: MTLCommandQueue
    private let device: MTLDevice

    /// How many times the rows have been written, which pins the flush path to
    /// one write per actual change.
    private(set) var writeCount = 0

    /// One queue carries every parameter texture's blits, since the writes are
    /// all main-actor.
    private static var sharedCommandQueue: MTLCommandQueue?

    init(rows: [SIMD4<Float>]) throws {
        var descriptor = LowLevelTexture.Descriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = MToonMaterialParameters.textureRowCount
        descriptor.height = 1
        descriptor.mipmapLevelCount = 1
        descriptor.textureUsage = [.shaderRead]
        texture = try LowLevelTexture(descriptor: descriptor)
        // Encoded on the device RealityKit gave the texture, which on a multi-GPU
        // machine need not be the system default.
        device = texture.read().device
        commandQueue = try Self.commandQueue(for: device)
        resource = try TextureResource(from: texture)
        try write(rows: rows)
    }

    /// Replaces every row. The texture is well under a page, so writing all of
    /// them costs less than tracking which moved.
    func write(rows: [SIMD4<Float>]) throws {
        precondition(rows.count == MToonMaterialParameters.textureRowCount)
        // A buffer of its own per write: the GPU reads it whenever it runs the
        // blit, and a few hundred bytes cost less than synchronizing a shared one.
        guard let buffer = rows.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else {
            throw VRMError._dataInconsistent("failed to allocate the MToon parameter staging buffer")
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw VRMError._dataInconsistent("failed to make a command buffer for the MToon parameter texture")
        }
        let destination = texture.replace(using: commandBuffer)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw VRMError._dataInconsistent("failed to encode the MToon parameter texture write")
        }
        blit.copy(from: buffer,
                  sourceOffset: 0,
                  sourceBytesPerRow: Self.bytesPerRow,
                  sourceBytesPerImage: Self.bytesPerRow,
                  sourceSize: MTLSize(width: rows.count, height: 1, depth: 1),
                  to: destination,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        writeCount += 1
    }

    private static func commandQueue(for device: MTLDevice) throws -> MTLCommandQueue {
        if let sharedCommandQueue, sharedCommandQueue.device === device {
            return sharedCommandQueue
        }
        guard let queue = device.makeCommandQueue() else {
            throw VRMError._dataInconsistent("failed to make a command queue for the MToon parameter texture")
        }
        sharedCommandQueue = queue
        return queue
    }
}

/// The filter half of a sampler parameter row.
///
/// glTF's `magFilter` and `minFilter` are independent, and `minFilter` itself
/// encodes both the minification texel filter and the mip filter. `MToon.metal`
/// reads ``index`` and applies all three itself, the 16 constant samplers a Metal
/// entry point allows being already spent on addressing modes.
struct MToonSamplerFilter {
    enum TexelFilter: Int, CaseIterable {
        case linear
        case nearest
    }

    /// Mirrors `MTLSamplerMipFilter`, including glTF's non-mipmapped filters.
    enum MipFilter: Int, CaseIterable {
        case none
        case nearest
        case linear
    }

    var magnification: TexelFilter = .linear
    var minification: TexelFilter = .linear
    var mip: MipFilter = .linear

    /// The encoding `mtoonFilteredSample` in `MToon.metal` decodes.
    var index: Int {
        (magnification.rawValue * TexelFilter.allCases.count + minification.rawValue)
            * MipFilter.allCases.count + mip.rawValue
    }

    /// The glTF default sampler: linear magnification and trilinear minification.
    static let `default` = MToonSamplerFilter()

    static let count = TexelFilter.allCases.count * TexelFilter.allCases.count * MipFilter.allCases.count
}

extension MToonSamplerFilter.MipFilter {
    init(_ mipFilter: MTLSamplerMipFilter) {
        switch mipFilter {
        case .nearest: self = .nearest
        case .linear: self = .linear
        case .notMipmapped: self = .none
        @unknown default: self = .linear
        }
    }
}

/// MToon texture slots. The raw value is also the sampler parameter row the
/// shader reads for this slot (see `mtoonSamplerParameter` in MToon.metal).
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

    /// Neutral texture bound when a material omits this slot, so the shader can
    /// sample unconditionally.
    enum Fallback {
        case white
        case neutralNormal
    }

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

    var fallback: Fallback {
        switch self {
        case .normal:
            return .neutralNormal
        case .base, .shade, .shadingShift, .matcap, .emissive, .rim, .outlineWidth, .uvAnimationMask:
            return .white
        }
    }
}

extension MToonMaterialDescriptor {
    /// The descriptor texture bound to `slot`. This is the single place the
    /// slot → MToon texture pairing is written down.
    func texture(for slot: MToonTextureSlot) -> Texture? {
        switch slot {
        case .base: return baseColorTexture
        case .shade: return shadeMultiplyTexture
        case .shadingShift: return shadingShiftTexture
        case .normal: return normalTexture
        case .matcap: return matcapTexture
        case .emissive: return emissiveTexture
        case .rim: return rimMultiplyTexture
        case .outlineWidth: return outlineWidthMultiplyTexture
        case .uvAnimationMask: return uvAnimationMaskTexture
        }
    }
}

#if !os(visionOS)
extension MToonMaterialDescriptor.CullMode {
    var faceCulling: CustomMaterial.FaceCulling {
        switch self {
        case .none: return .none
        case .front: return .front
        case .back: return .back
        }
    }
}
#endif

private extension MToonMaterialDescriptor.OutlineWidthMode {
    /// Encoding read back by MToon.metal as `outlineParams.y` (> 1.5h means screen space).
    var mtoonRawValue: Float {
        switch self {
        case .none: return 0
        case .worldCoordinates: return 1
        case .screenCoordinates: return 2
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
