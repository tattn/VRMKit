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
    static let logger = Logger(subsystem: "com.github.tattn.VRMKit", category: "MToon")
    static let extensionName = GLTFExtension.materialsMToon.rawValue

    /// Which materials this shader renders as MToon.
    public enum Source: Sendable {
        /// Only materials authored as MToon. The default.
        case authoredOnly
        /// Materials authored as MToon keep their authored values, and every
        /// other material, PBR and Unlit alike, is converted to MToon with
        /// the given style. The conversion is not part of the VRM specification.
        case convertAll(MToonConversionStyle)

        /// Converts every material with the default ``MToonConversionStyle``.
        public static var convertAll: Source { .convertAll(MToonConversionStyle()) }
    }

    /// When an MToon material gets the sibling entity drawing its inverted-hull
    /// outline. The pass set is fixed at load, and a pass can be hidden at runtime
    /// with ``GLTFEntity/setPassEnabled(_:named:)``.
    public enum OutlinePass: Sendable {
        /// A pass for materials whose MToon data draws an outline. The default.
        case automatic
        /// No outline passes; even authored outlines are not drawn.
        case never
    }

    /// The ``GLTFShadedMaterial/Pass/name`` of the outline pass, so the mesh
    /// "hair" is outlined by its sibling "hair_mtoonOutline".
    public static let outlinePassName = "mtoonOutline"

    public let source: Source
    public let outlinePass: OutlinePass
    /// Whether the shader pre-inverts RealityKit's tone mapping so the toon color
    /// survives it. That is what a `RealityView` needs. A `RealityRenderer` that
    /// has turned tone mapping off (`cameraSettings.isToneMappingEnabled`) passes
    /// `false` and gets the color as is, which also sidesteps the inversion table
    /// being calibrated for one platform's tone curve.
    public let compensatesToneMapping: Bool
    /// The Metal functions the material and its outline are drawn with.
    public let functions: MToonShaderFunctions

    public init(source: Source = .authoredOnly,
                outlinePass: OutlinePass = .automatic,
                compensatesToneMapping: Bool = true,
                functions: MToonShaderFunctions = MToonShaderFunctions()) {
        self.source = source
        self.outlinePass = outlinePass
        self.compensatesToneMapping = compensatesToneMapping
        self.functions = functions
    }

#if !os(visionOS)
    /// Everything derived from one MToon material. A non-nil state is what
    /// "renders as MToon" means.
    private struct MToonState {
        let descriptor: MToonMaterialDescriptor
        let parameters: MToonMaterialParameters
        let parameterTexture: CustomMaterial.Texture
        let functions: MToonShaderFunctions.Resolved
    }

    /// Kept with a failure too, so a load that cannot succeed is not retried per material.
    private var resolvedFunctions: Result<MToonShaderFunctions.Resolved, Error>?
#endif

    /// Empty where no Metal library is bundled.
    public var supportedRequiredExtensions: Set<String> {
        MToonShaderLibraryLoader.resourceName != nil ? [Self.extensionName] : []
    }

    /// A rendering the document has ruled out, because a required extension asks
    /// for more than this renderer draws. It fails the material outright rather
    /// than falling through to the rest of the chain.
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
            // A document requiring `VRMC_materials_mtoon` cannot be drawn without MToon
            // at all, whatever draws the material next.
            guard !isMToonRequired(by: context),
                  !(error is UnrenderableRequirement) else { throw error }
            logFallback(error, context: context)
            return nil
        }
#endif
    }

#if !os(visionOS)
    /// Whether the document declares itself undrawable without MToon, on a
    /// platform this shader claims MToon on. Where it claims nothing the loader
    /// has already reported the required extension.
    private func isMToonRequired(by context: GLTFMaterialShaderContext) -> Bool {
        supportedRequiredExtensions.contains(Self.extensionName)
            && context.enforcesRequiredExtension(Self.extensionName)
    }

    private func logFallback(_ error: Error, context: GLTFMaterialShaderContext) {
        // A library failure fails every MToon material of the document alike,
        // so it is reported once instead of per material.
        if error is MToonShaderLibraryLoaderError {
            context.logOnce("mtoonLibrary",
                            "Failed to load the MToon shader functions, so MToon materials render as Unlit approximations: \(String(describing: error))")
        } else {
            Self.logger.error("Failed to build the MToon material \(context.materialIndex, privacy: .public); passing it on to the rest of the shader chain: \(String(describing: error), privacy: .public)")
        }
    }

    private func shadedMToonMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
        guard let state = try makeState(for: context) else { return nil }
        // Every loaded entity graph gets a state of its own, starting from these rows.
        let parameters = state.parameters
        let descriptor = state.descriptor
        var shaded = GLTFShadedMaterial(material: try customMToonMaterial(state, context: context),
                                        renderQueue: context.renderQueue(alphaMode: descriptor.alphaMode,
                                                                         transparentWithZWrite: descriptor.transparentWithZWrite,
                                                                         offset: descriptor.renderQueueOffsetNumber),
                                        makeAnimatableState: { MToonAnimatableMaterialState(parameters: parameters) })
        if outlinePass == .automatic, descriptor.hasOutline {
            var pass = GLTFShadedMaterial.Pass(material: try customMToonOutlineMaterial(state, context: context),
                                               name: Self.outlinePassName)
            pass.applyBoundsBudget = Self.applyingOutlineBudget
            shaded.additionalPasses = [pass]
        }
        return shaded
    }

    private func makeState(for context: GLTFMaterialShaderContext) throws -> MToonState? {
        guard let descriptor = try resolvedDescriptor(for: context) else { return nil }
        let functions = try resolveFunctions()
        let textureTransform = try textureTransform(for: context, descriptor: descriptor)
        let parameters = try parameters(for: descriptor, textureTransform: textureTransform, context: context)
        return MToonState(descriptor: descriptor,
                          parameters: parameters,
                          parameterTexture: CustomMaterial.Texture(try MToonParameterTexture(rows: parameters.packedRows).resource),
                          functions: functions)
    }

    private func resolveFunctions() throws -> MToonShaderFunctions.Resolved {
        if let resolvedFunctions {
            return try resolvedFunctions.get()
        }
        let result = Result { try functions.resolved() }
        resolvedFunctions = result
        return try result.get()
    }

    /// The authored MToon model, or under ``Source/convertAll(_:)`` one synthesized from
    /// the material's standard Unlit / PBR values.
    ///
    /// A material authored against an unimplemented MToon version is neither, and drops to
    /// the Unlit approximation the specification names as the fallback, unless the document
    /// requires the extension.
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
            return StandardMToonConverter.convert(material: context.material,
                                                 vrm0Property: context.vrm0MaterialProperty,
                                                 style: style)
        }
    }

    private func customMToonMaterial(_ state: MToonState,
                                     context: GLTFMaterialShaderContext) throws -> Material {
        let mtoon = state.descriptor
        var material = try sharedCustomMaterial(state, surface: state.functions.surface, context: context)
        // MToon needs more textures than CustomMaterial has semantic channels, so the
        // extra slots ride on unrelated ones. MToon.metal reads them back the same way.
        material.roughness.texture = try mtoonTexture(mtoon, slot: .shade, context: context)
        material.specular.texture = try mtoonTexture(mtoon, slot: .shadingShift, context: context)
        material.metallic.texture = try mtoonTexture(mtoon, slot: .matcap, context: context)
        material.normal.texture = try mtoonTexture(mtoon, slot: .normal, context: context)
        material.emissiveColor = .init(color: .white, texture: try mtoonTexture(mtoon, slot: .emissive, context: context))
        material.clearcoatRoughness.texture = try mtoonTexture(mtoon, slot: .rim, context: context)
        // No outline-width map: only the outline pass's geometry modifier reads
        // it, and it binds one of its own.
        material.faceCulling = mtoon.cullMode.faceCulling
        return material
    }

    private func customMToonOutlineMaterial(_ state: MToonState,
                                            context: GLTFMaterialShaderContext) throws -> Material {
        var material = try sharedCustomMaterial(state,
                                                surface: state.functions.outlineSurface,
                                                geometry: state.functions.outlineGeometry,
                                                context: context)
        material.faceCulling = .front
        material.clearcoat.texture = try mtoonTexture(state.descriptor, slot: .outlineWidth, context: context)
        return material
    }

    /// What the material and its outline share: the base color both cut out by, the UV
    /// animation mask, blending, depth writes and the parameter rows.
    private func sharedCustomMaterial(_ state: MToonState,
                                      surface: MToonShaderFunctions.Function,
                                      geometry: MToonShaderFunctions.Function? = nil,
                                      context: GLTFMaterialShaderContext) throws -> CustomMaterial {
        let mtoon = state.descriptor
        let surfaceShader = CustomMaterial.SurfaceShader(named: surface.name, in: surface.library)
        var material = if let geometry {
            try CustomMaterial(surfaceShader: surfaceShader,
                               geometryModifier: .init(named: geometry.name, in: geometry.library),
                               lightingModel: .unlit)
        } else {
            try CustomMaterial(surfaceShader: surfaceShader, lightingModel: .unlit)
        }
        material.baseColor = .init(tint: .white, texture: try mtoonTexture(mtoon, slot: .base, context: context))
        material.ambientOcclusion.texture = try mtoonTexture(mtoon, slot: .uvAnimationMask, context: context)
        applyAlphaMode(mtoon.alphaMode, alphaCutoff: mtoon.alphaCutoff, to: &material)
        applyDepthWrite(mtoon, to: &material)
        applyParameters(state, to: &material)
        return material
    }

    /// MToon.metal applies the UV transform from the parameter rows, so
    /// `textureCoordinateTransform` is left at identity here. `custom.value` carries what
    /// is not the material's: x the tone-mapping flag, and w the outline budget, 0 (read
    /// as unbudgeted) until the loader writes the real one per pass entity.
    private func applyParameters(_ state: MToonState, to material: inout CustomMaterial) {
        material.custom.value = SIMD4<Float>(compensatesToneMapping ? 1 : 0, 0, 0, 0)
        material.custom.texture = state.parameterTexture
    }

    /// Hands the outline's geometry modifier the room the loader granted its
    /// pass outside the mesh's bounding box, in the mesh's own space.
    private nonisolated static func applyingOutlineBudget(_ material: any Material, _ budget: Float) -> any Material {
        guard var material = material as? CustomMaterial else { return material }
        material.custom.value.w = budget
        return material
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

    /// RealityKit gives a material one UV transform and its mesh one UV set, so MToon
    /// draws all of its textures through the first UV-accessed texture's
    /// `KHR_texture_transform`, on the UV set the core material selected.
    ///
    /// Covers the textures only MToon names, which the loader never sees. A document that
    /// merely uses the extension renders through the approximation and logs it; one that
    /// requires it fails the material instead.
    private func validateTextureTransformsAreRenderable(_ textures: [MToonMaterialDescriptor.Texture],
                                                        context: GLTFMaterialShaderContext) throws {
        guard context.enforcesRequiredExtension(GLTFExtension.textureTransform.rawValue) else { return }
        if let conflict = textures.textureTransformConflict(selectedTexCoord: context.selectedTexCoord) {
            throw UnrenderableRequirement(description: """
                this glTF requires KHR_texture_transform, and MToon material \(context.materialIndex) \(conflict), \
                which this renderer cannot draw
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

    /// (wrapS, wrapT, filterIndex, 0), the sampler row layout `MToonRealityKit.h` expects.
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
public final class MToonAnimatableMaterialState: VRMAnimatableMaterialState {
    /// The rows left to the app, for its own ``MToonShaderFunctions`` to read. They start
    /// at zero and the bundled functions ignore them.
    public static let userParameterCount = MToonMaterialParameters.userRowCount

    private(set) var parameters: MToonMaterialParameters
    /// This entity's own rows on the GPU, written in place. The loader hands every entity
    /// graph the same material, so the first flush swaps in this one.
    private(set) var parameterTexture: MToonParameterTexture?
    /// Whether ``apply(to:)`` has put ``parameterTexture`` on the materials yet.
    private var isParameterTextureInstalled = false

    init(parameters: MToonMaterialParameters) {
        self.parameters = parameters
    }

    /// Read in Metal as `mtoonUserParameter(textures, index)`.
    public func userParameter(at index: Int) -> SIMD4<Float> {
        parameters.userRows[index]
    }

    /// Returns whether the row changed.
    @discardableResult
    public func setUserParameter(_ value: SIMD4<Float>, at index: Int) -> Bool {
        guard parameters.userRows[index] != value else { return false }
        parameters.userRows[index] = value
        return true
    }

    // MToon has a row for every bindable value, so it claims all of them.

    public func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float>? {
        parameters.color(for: type)
    }

    public func setColor(_ color: SIMD4<Float>,
                         for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Bool {
        parameters.setColor(color, for: type)
        return true
    }

    public var textureTransform: MaterialParameterTypes.TextureCoordinateTransform? {
        parameters.textureTransform
    }

    public func setTextureTransform(scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float) -> Bool {
        parameters.setTextureTransform(scale: scale, offset: offset, rotation: rotation)
        return true
    }

    // The light setters return whether the rows changed.

    /// The light direction rides in its own parameter row, so tracking a light per frame
    /// is one texture blit rather than a `ModelComponent` rewrite on every material.
    func setLightDirection(_ direction: SIMD3<Float>) -> Bool {
        guard simd_distance(direction, parameters.lightDirection) > 0.0001 else { return false }
        parameters.lightDirection = direction
        return true
    }

    func setLightColor(_ color: SIMD3<Float>) -> Bool {
        let row = SIMD4<Float>(color, 1)
        guard row != parameters.lightColor else { return false }
        parameters.lightColor = row
        return true
    }

    func setAmbientColor(_ color: SIMD3<Float>) -> Bool {
        let row = SIMD4<Float>(color, 1)
        guard row != parameters.ambientColor else { return false }
        parameters.ambientColor = row
        return true
    }

    /// The rows are blitted on a queue of their own.
    public func waitForWrites() {
        parameterTexture?.waitForWrites()
    }

    /// The first flush of the copy builds a texture of its own.
    public func detached() -> (any VRMAnimatableMaterialState)? {
        MToonAnimatableMaterialState(parameters: parameters)
    }

    public func prepareFlush() -> Bool {
        do {
            let rows = parameters.packedRows
            if let parameterTexture {
                try parameterTexture.write(rows: rows)
            } else {
                parameterTexture = try MToonParameterTexture(rows: rows)
            }
            return true
        } catch {
            MToonShader.logger.error("Failed to update MToon parameter texture: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Only the first flush has anything to push: every write after it lands in the
    /// parameter texture the materials already sample.
    public var updatesMaterialsOnFlush: Bool {
        !isParameterTextureInstalled
    }

    public func apply(to material: any Material) -> any Material {
#if os(visionOS)
        return material
#else
        guard var material = material as? CustomMaterial, let parameterTexture else { return material }
        material.custom.texture = CustomMaterial.Texture(parameterTexture.resource)
        isParameterTextureInstalled = true
        return material
#endif
    }
}
#endif
