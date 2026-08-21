#if canImport(RealityKit)
import CoreGraphics
import Foundation
import Metal
import OSLog
import RealityKit
import VRMKit
import VRMKitRuntime

/// Renders materials carrying MToon data, either the `VRMC_materials_mtoon`
/// glTF extension or a VRM 0.x MToon material property, through a
/// `CustomMaterial` toon shader with a precompiled Metal library.
///
/// Part of every loader's default shader chain. On platforms without
/// `CustomMaterial` or a bundled Metal library (visionOS, Mac Catalyst) it
/// claims no material, so the loader's built-in path renders MToon materials as
/// Unlit approximations instead.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class MToonShader: GLTFMaterialShader {
    static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "MToon")
    static let extensionName = "VRMC_materials_mtoon"

    /// Which materials this shader renders as MToon.
    public enum Source: Sendable {
        /// Only materials authored as MToon, through the
        /// `VRMC_materials_mtoon` extension or a VRM 0.x MToon material
        /// property. The default.
        case authoredOnly
        /// Materials authored as MToon keep their authored values, and every
        /// other material, PBR and Unlit alike, is converted to MToon with
        /// the given style.
        case convertAll(MToonConversionStyle)

        /// Converts every material with the default ``MToonConversionStyle``.
        public static var convertAll: Source { .convertAll(MToonConversionStyle()) }
    }

    /// Which materials render as MToon.
    public let source: Source
    /// Controls creation of MToon's inverted-hull outline pass.
    public let isOutlineEnabled: Bool

    public init(source: Source = .authoredOnly, isOutlineEnabled: Bool = true) {
        self.source = source
        self.isOutlineEnabled = isOutlineEnabled
    }

#if !os(visionOS)
    /// Everything derived from one MToon material. A non-nil state is what
    /// "this material renders as MToon" means.
    private struct MToonState {
        let descriptor: MToonMaterialDescriptor
        let parameters: MToonMaterialParameters
        let parameterTexture: CustomMaterial.Texture
        let library: MTLLibrary
    }
#endif

    /// `resourceName` is nil on every platform without a bundled MToon Metal
    /// library (visionOS, Mac Catalyst), so this claims nothing there.
    public var supportedRequiredExtensions: Set<String> {
        MToonShaderLibraryLoader.resourceName != nil ? [Self.extensionName] : []
    }

    /// A rendering the document has ruled out, because a required extension asks
    /// for more than this renderer draws. Unlike a build failure it never falls
    /// through to the rest of the chain, since no other path draws it any
    /// better, so it fails the material outright.
    struct UnrenderableRequirement: Error, CustomStringConvertible {
        let description: String
    }

    public func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
#if os(visionOS)
        return nil
#else
        do {
            return try shadedMToonMaterial(for: context)
        } catch {
            // Two things rule the fall-through out: a document that requires
            // `VRMC_materials_mtoon` cannot be drawn without MToon at all, and an
            // `UnrenderableRequirement` is a rendering it has ruled out whatever
            // draws the material next.
            guard !isMToonRequired(by: context),
                  !(error is UnrenderableRequirement) else { throw error }
            logFallback(error, context: context)
            return nil
        }
#endif
    }

#if !os(visionOS)
    /// Whether the document declares itself undrawable without MToon, on a
    /// platform this shader claims MToon on. Where it claims nothing, for want
    /// of a bundled Metal library, the loader has already reported the required
    /// extension, and rendering the Unlit approximation is all there is.
    private func isMToonRequired(by context: GLTFMaterialShaderContext) -> Bool {
        supportedRequiredExtensions.contains(Self.extensionName)
            && context.enforcesRequiredExtension(Self.extensionName)
    }

    private func logFallback(_ error: Error, context: GLTFMaterialShaderContext) {
        // A library failure fails every MToon material of the document alike,
        // so it is reported once instead of per material.
        if error is MToonShaderLibraryLoaderError {
            context.logOnce("mtoonLibrary",
                            "Failed to load the bundled MToon shader library, so MToon materials render as Unlit approximations: \(String(describing: error))")
        } else {
            Self.logger.error("Failed to build the MToon material \(context.materialIndex, privacy: .public); passing it on to the rest of the shader chain: \(String(describing: error), privacy: .public)")
        }
    }

    private func shadedMToonMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
        guard let state = try makeState(for: context) else { return nil }
        // The rows the expression runtime animates are built right here, so the
        // state factory only has to hand every entity graph its own copy.
        let parameters = state.parameters
        var shaded = GLTFShadedMaterial(material: try customMToonMaterial(state, context: context),
                                        makeAnimatableState: { MToonAnimatableMaterialState(parameters: parameters) })
        if isOutlineEnabled, state.descriptor.hasOutline {
            let outline = try customMToonOutlineMaterial(state, context: context)
            shaded.additionalPasses = [.init(material: outline, name: "outline")]
        }
        return shaded
    }

    private func makeState(for context: GLTFMaterialShaderContext) throws -> MToonState? {
        guard let descriptor = try resolvedDescriptor(for: context) else { return nil }
        let library = try MToonShaderLibraryLoader.loadDefault()
        let textureTransform = try textureTransform(for: context, descriptor: descriptor)
        let parameters = try parameters(for: descriptor, textureTransform: textureTransform, context: context)
        logUnsupportedFeatures(of: descriptor, index: context.materialIndex)
        return MToonState(descriptor: descriptor,
                          parameters: parameters,
                          parameterTexture: CustomMaterial.Texture(try parameters.textureResource()),
                          library: library)
    }

    /// The MToon material model to render: the authored one when the material
    /// carries MToon data, else, under ``Source/convertAll(_:)``, one
    /// synthesized from its standard Unlit / PBR values.
    ///
    /// A material authored against an unimplemented MToon version is neither:
    /// converting it would invent toon values over the ones it already has, so it
    /// drops to the Unlit approximation the MToon specification names as the
    /// fallback — unless the document requires the extension.
    private func resolvedDescriptor(for context: GLTFMaterialShaderContext) throws -> MToonMaterialDescriptor? {
        switch try context.mtoonResolution() {
        case .supported(let authored):
            return authored
        case .unsupportedVersion(let specVersion):
            guard !isMToonRequired(by: context) else {
                throw UnrenderableRequirement(description: """
                    this glTF requires \(Self.extensionName) at specVersion \(specVersion), which this \
                    renderer does not implement
                    """)
            }
            // The loader logs the version, for the built-in path too.
            return nil
        case .none:
            guard case .convertAll(let style) = source else { return nil }
            return StandardMToonConverter.migrate(material: context.material,
                                                  vrm0Property: context.vrm0MaterialProperty,
                                                  shadeColorScale: style.shadeColorScale,
                                                  shadingToonyFactor: style.shadingToonyFactor,
                                                  shadingShiftFactor: style.shadingShiftFactor,
                                                  outlineWidthFactor: style.outlineWidthFactor,
                                                  outlineColorFactor: style.outlineColorFactor)
        }
    }

    private func logUnsupportedFeatures(of descriptor: MToonMaterialDescriptor, index: Int) {
        if descriptor.renderQueueOffsetNumber != 0 {
            Self.logger.warning("MToon material \(index, privacy: .public) requests renderQueueOffsetNumber \(descriptor.renderQueueOffsetNumber); RealityKit has no material-level draw-order hook, so it is ignored.")
        }
    }

    private func customMToonMaterial(_ state: MToonState,
                                     context: GLTFMaterialShaderContext) throws -> Material {
        let mtoon = state.descriptor
        let surface = CustomMaterial.SurfaceShader(named: "mtoonSurface", in: state.library)
        var material = try CustomMaterial(surfaceShader: surface, lightingModel: .unlit)
        // MToon needs more textures than CustomMaterial has semantic channels, so the
        // extra slots ride on unrelated ones; MToon.metal reads them back the same way.
        material.baseColor = .init(tint: .white, texture: try mtoonTexture(mtoon, slot: .base, context: context))
        material.roughness.texture = try mtoonTexture(mtoon, slot: .shade, context: context)
        material.specular.texture = try mtoonTexture(mtoon, slot: .shadingShift, context: context)
        material.metallic.texture = try mtoonTexture(mtoon, slot: .matcap, context: context)
        material.normal.texture = try mtoonTexture(mtoon, slot: .normal, context: context)
        material.emissiveColor = .init(color: .white, texture: try mtoonTexture(mtoon, slot: .emissive, context: context))
        material.clearcoatRoughness.texture = try mtoonTexture(mtoon, slot: .rim, context: context)
        material.clearcoat.texture = try mtoonTexture(mtoon, slot: .outlineWidth, context: context)
        material.ambientOcclusion.texture = try mtoonTexture(mtoon, slot: .uvAnimationMask, context: context)

        applyAlphaMode(mtoon.alphaMode, alphaCutoff: mtoon.alphaCutoff, to: &material)
        applyDepthWrite(mtoon, to: &material)
        material.faceCulling = mtoon.cullMode.faceCulling
        applyParameters(state, to: &material)
        return material
    }

    private func customMToonOutlineMaterial(_ state: MToonState,
                                            context: GLTFMaterialShaderContext) throws -> Material {
        let mtoon = state.descriptor
        let surface = CustomMaterial.SurfaceShader(named: "mtoonOutlineSurface", in: state.library)
        let geometry = CustomMaterial.GeometryModifier(named: "mtoonOutlineGeometry", in: state.library)
        var material = try CustomMaterial(surfaceShader: surface,
                                          geometryModifier: geometry,
                                          lightingModel: .unlit)
        material.faceCulling = .front
        material.baseColor = .init(tint: .white, texture: try mtoonTexture(mtoon, slot: .base, context: context))
        material.clearcoat.texture = try mtoonTexture(mtoon, slot: .outlineWidth, context: context)
        material.ambientOcclusion.texture = try mtoonTexture(mtoon, slot: .uvAnimationMask, context: context)
        applyAlphaMode(mtoon.alphaMode, alphaCutoff: mtoon.alphaCutoff, to: &material)
        applyDepthWrite(mtoon, to: &material)
        applyParameters(state, to: &material)
        return material
    }

    /// MToon.metal applies the UV transform from the parameter rows, so
    /// `textureCoordinateTransform` is deliberately left at identity here.
    private func applyParameters(_ state: MToonState, to material: inout CustomMaterial) {
        material.custom.value = state.parameters.customValue
        material.custom.texture = state.parameterTexture
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout CustomMaterial) {
        let settings = GLTFAlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

    /// MToon's `transparentWithZWrite` asks a blended material to still write depth.
    private func applyDepthWrite(_ mtoon: MToonMaterialDescriptor, to material: inout CustomMaterial) {
        material.writesDepth = mtoon.alphaMode != .BLEND || mtoon.transparentWithZWrite
    }

    /// The descriptor's texture for `slot`, or the slot's neutral fallback.
    private func mtoonTexture(_ descriptor: MToonMaterialDescriptor,
                              slot: MToonTextureSlot,
                              context: GLTFMaterialShaderContext) throws -> CustomMaterial.Texture {
        guard let texture = descriptor.texture(for: slot) else {
            return CustomMaterial.Texture(try fallbackTextureResource(slot.fallback))
        }
        return CustomMaterial.Texture(try context.texture(withTextureIndex: texture.index, semantic: slot.semantic))
    }

    private func parameters(for descriptor: MToonMaterialDescriptor,
                            textureTransform: MaterialParameterTypes.TextureCoordinateTransform,
                            context: GLTFMaterialShaderContext) throws -> MToonMaterialParameters {
        var parameters = MToonMaterialParameters(descriptor)
        parameters.setTextureTransform(scale: textureTransform.scale,
                                       offset: textureTransform.offset,
                                       rotation: textureTransform.rotation)
        for slot in MToonTextureSlot.allCases {
            try parameters.setSampler(samplerParameters(for: descriptor.texture(for: slot), context: context),
                                      for: slot)
        }
        return parameters
    }

    /// MToon.metal transforms in glTF UV space, so unlike the standard path the
    /// transform passes through unconverted.
    private func textureTransform(for context: GLTFMaterialShaderContext,
                                  descriptor: MToonMaterialDescriptor) throws -> MaterialParameterTypes.TextureCoordinateTransform {
        let textures = descriptor.uvAccessedTextures
        try validateTextureTransformsAreRenderable(textures, context: context)
        let selectedTexCoord = context.selectedTexCoord
        if textures.contains(where: { $0.texCoord != selectedTexCoord }) {
            context.logOnce("mtoonTexCoord-\(context.materialIndex)", """
                MToon material \(context.materialIndex) samples several UV sets; RealityKit meshes carry \
                one UV channel, so every MToon texture is sampled with UV set \(selectedTexCoord).
                """)
        }
        let selected = context.selectedUVTransform(for: textures)
        return MaterialParameterTypes.TextureCoordinateTransform(offset: selected.offset,
                                                                 scale: selected.scale,
                                                                 rotation: selected.rotation)
    }

    /// RealityKit gives a material one UV transform, and its mesh one UV set, so
    /// MToon draws all of its textures through the first UV-accessed texture's
    /// `KHR_texture_transform`, on the UV set the core material selected.
    ///
    /// The loader checks the same limit over the core glTF material; this covers
    /// the textures only MToon names (the shade, shading-shift, rim, outline
    /// width and UV-animation mask maps), which the loader never sees. A document
    /// that merely *uses* the extension renders through the approximation and
    /// logs it; one that *requires* it is asking for a result no path of this
    /// renderer draws, so the material fails instead.
    private func validateTextureTransformsAreRenderable(_ textures: [MToonMaterialDescriptor.Texture],
                                                        context: GLTFMaterialShaderContext) throws {
        guard context.enforcesRequiredExtension("KHR_texture_transform") else { return }
        let index = context.materialIndex
        let selectedTexCoord = context.selectedTexCoord
        guard textures.allSatisfy({ $0.texCoord == selectedTexCoord }) else {
            throw UnrenderableRequirement(description: """
                this glTF requires KHR_texture_transform, and MToon material \(index) samples UV sets \
                other than \(selectedTexCoord), which this renderer cannot draw
                """)
        }
        let transforms = textures.map { $0.transform ?? GLTFUVTransform() }
        guard transforms.allSatisfy({ $0 == transforms.first }) else {
            throw UnrenderableRequirement(description: """
                this glTF requires KHR_texture_transform, and MToon material \(index) gives its textures \
                different transforms, which this renderer cannot draw
                """)
        }
    }

    private func samplerParameters(for texture: MToonMaterialDescriptor.Texture?,
                                   context: GLTFMaterialShaderContext) throws -> SIMD4<Float> {
        guard let texture,
              let sampler = try context.gltfSampler(withTextureIndex: texture.index) else {
            return MToonMaterialParameters.defaultSampler
        }
        return samplerParameters(sampler)
    }

    /// (wrapS, wrapT, filterIndex, 0), the sampler row layout `MToon.metal` expects.
    private func samplerParameters(_ sampler: GLTF.Sampler) -> SIMD4<Float> {
        let (minFilter, mipFilter) = (sampler.minFilter ?? .LINEAR_MIPMAP_LINEAR).metalFilters
        let filter = MToonSamplerFilter(
            magnification: (sampler.magFilter ?? .LINEAR).metalFilter == .nearest ? .nearest : .linear,
            minification: minFilter == .nearest ? .nearest : .linear,
            mip: MToonSamplerFilter.MipFilter(mipFilter)
        )
        return SIMD4<Float>(wrapMode(sampler.wrapS),
                            wrapMode(sampler.wrapT),
                            Float(filter.index),
                            0)
    }

    private func wrapMode(_ wrap: GLTF.Sampler.Wrap) -> Float {
        switch wrap {
        case .REPEAT: return 0
        case .CLAMP_TO_EDGE: return 1
        case .MIRRORED_REPEAT: return 2
        }
    }

    private var fallbackTextureCache: [MToonTextureSlot.Fallback: TextureResource] = [:]

    /// The neutral 1x1 texture bound when a material omits an MToon slot.
    private func fallbackTextureResource(_ fallback: MToonTextureSlot.Fallback) throws -> TextureResource {
        if let cached = fallbackTextureCache[fallback] {
            return cached
        }
        let texture: TextureResource
        switch fallback {
        case .white:
            texture = try solidColorTextureResource(rgba: [255, 255, 255, 255], semantic: .color)
        case .neutralNormal:
            texture = try solidColorTextureResource(rgba: [128, 128, 255, 255], semantic: .normal)
        }
        fallbackTextureCache[fallback] = texture
        return texture
    }

    private func solidColorTextureResource(rgba: [UInt8],
                                           semantic: TextureResource.Semantic) throws -> TextureResource {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: 1,
                                  height: 1,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw VRMError._dataInconsistent("failed to create 1x1 \(semantic) texture")
        }
        return try TextureResource(image: image, options: .init(semantic: semantic))
    }
#endif
}

/// The mutable MToon parameter rows of one material, held per loaded entity so
/// expression changes on one entity never reach another.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class MToonAnimatableMaterialState: VRMAnimatableMaterialState {
    private(set) var parameters: MToonMaterialParameters
#if !os(visionOS)
    /// The last texture ``prepareFlush()`` baked, pre-wrapped so applying it to
    /// several materials shares one wrapper. Until the first flush the material
    /// keeps the parameter texture it was built with.
    private var bakedTexture: CustomMaterial.Texture?
#endif

    init(parameters: MToonMaterialParameters) {
        self.parameters = parameters
    }

    // MToon has a row for every bindable value, so it claims all of them.

    func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float>? {
        parameters.color(for: type)
    }

    func setColor(_ color: SIMD4<Float>,
                  for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Bool {
        parameters.setColor(color, for: type)
        return true
    }

    var textureTransform: MaterialParameterTypes.TextureCoordinateTransform? {
        parameters.textureTransform
    }

    func setTextureTransform(scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float) -> Bool {
        parameters.setTextureTransform(scale: scale, offset: offset, rotation: rotation)
        return true
    }

    /// The light direction rides in `custom.value` rather than in a parameter
    /// row, so it reaches the materials through ``apply(to:)`` alone, without
    /// rebuilding the packed texture, and without clearing a rebuild an earlier
    /// row change is still waiting for.
    func setLightDirection(_ direction: SIMD3<Float>) {
        parameters.lightDirection = direction
    }

    func setLighting(color: SIMD3<Float>, ambient: SIMD3<Float>) {
        parameters.lightColor = SIMD4<Float>(color, 1)
        parameters.ambientColor = SIMD4<Float>(ambient, 1)
    }

    func prepareFlush() -> Bool {
#if os(visionOS)
        return true
#else
        do {
            bakedTexture = CustomMaterial.Texture(try parameters.textureResource())
            return true
        } catch {
            MToonShader.logger.error("Failed to update MToon parameter texture: \(error.localizedDescription, privacy: .public)")
            return false
        }
#endif
    }

    func apply(to material: any Material) -> any Material {
#if os(visionOS)
        return material
#else
        guard var material = material as? CustomMaterial else { return material }
        material.custom.value = parameters.customValue
        if let bakedTexture {
            material.custom.texture = bakedTexture
        }
        return material
#endif
    }

    /// The light direction rides in `custom.value` alone, so this pushes it
    /// without touching the parameter texture. That is cheap enough for
    /// per-frame light tracking, and it cannot clear a rebuild an earlier row
    /// change is still waiting for.
    func applyLightDirection(to material: any Material) -> any Material {
#if os(visionOS)
        return material
#else
        guard var material = material as? CustomMaterial else { return material }
        material.custom.value = parameters.customValue
        return material
#endif
    }
}
#endif
