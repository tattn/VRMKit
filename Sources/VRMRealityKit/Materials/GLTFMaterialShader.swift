#if canImport(RealityKit)
import RealityKit
import VRMKit
import VRMKitRuntime

/// One way of drawing glTF materials.
///
/// A loader consults its shader chain in order and renders each material with
/// the first shader that returns a non-nil ``GLTFShadedMaterial``. Materials no
/// shader claims render through the loader's built-in Unlit / PBR path, which
/// implements the glTF core specification and cannot be removed.
///
/// A shader replaces material *construction* only. The mesh it draws is the one
/// the loader builds from the core glTF material: that material's textures
/// decide which UV set the mesh carries, and its normal texture decides whether
/// tangents are generated. A shader cannot ask for vertex data the core material
/// does not, so it renders within those inputs.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public protocol GLTFMaterialShader: AnyObject {
    /// The materials this shader builds for the context's material, or nil to
    /// pass it on to the next shader in the chain (and ultimately the built-in
    /// Unlit / PBR path).
    ///
    /// A thrown error fails the material instead of falling through: the
    /// generic glTF load rethrows it, while a VRM load falls back to the
    /// default material. A shader that can degrade gracefully, the way MToon
    /// falls back to Unlit, should catch its own errors and return nil, unless
    /// the document lists its extension in `extensionsRequired`: rendering
    /// without it is then not a degradation the document allows.
    func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial?

    /// glTF extensions this shader implements, merged into the loader's
    /// `extensionsRequired` validation. Defaults to none.
    ///
    /// Only claim an extension this shader can draw from the material alone:
    /// the mesh inputs are fixed, as described above.
    var supportedRequiredExtensions: Set<String> { get }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public extension GLTFMaterialShader {
    var supportedRequiredExtensions: Set<String> { [] }
}

/// What one glTF material renders as: the material itself, plus any additional
/// render passes drawn as sibling model entities of the same mesh.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFShadedMaterial {
    /// One extra render pass of a shaded material, drawn by a sibling model
    /// entity sharing the mesh, such as MToon's inverted-hull outline.
    public struct Pass {
        public var material: any Material
        /// Appended to the mesh's name to name the pass entity: "outline" of the
        /// mesh "mesh_0" is drawn by "mesh_0_outline".
        public var name: String

        public init(material: any Material, name: String) {
            self.material = material
            self.name = name
        }
    }

    public var material: any Material
    /// Extra passes, added to the scene before the main model entity.
    public var additionalPasses: [Pass]
    /// Makes a fresh ``VRMAnimatableMaterialState`` for this material, letting
    /// VRM expressions (`materialColorBind` / `textureTransformBind`) drive it
    /// the way MToon does. Every loaded entity graph calls it once per material,
    /// so animating one entity never affects another.
    ///
    /// Leaving it nil is fine, and so is a state claiming only some values:
    /// everything unclaimed falls back to mutating the RealityKit material
    /// properties directly, which only reaches the standard material types.
    public var makeAnimatableState: (@MainActor () -> any VRMAnimatableMaterialState)?

    public init(material: any Material,
                additionalPasses: [Pass] = [],
                makeAnimatableState: (@MainActor () -> any VRMAnimatableMaterialState)? = nil) {
        self.material = material
        self.additionalPasses = additionalPasses
        self.makeAnimatableState = makeAnimatableState
    }
}

/// One material of the document being loaded, plus the loader services a shader
/// builds it from. Only valid during the call it is passed to.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public struct GLTFMaterialShaderContext {
    /// The loader building the material. The service methods below go through
    /// its caches, so shaders share decoded textures with the built-in paths.
    let loader: GLTFEntityLoader
    /// Index of ``material`` in the document's `materials`.
    public let materialIndex: Int
    /// The glTF material to build.
    public let material: GLTF.Material
    /// The VRM 0.x Unity material property describing ``material``, when the
    /// document is a VRM 0.x model.
    ///
    /// Not public: a VRM 0.x material model hanging off a generic glTF context
    /// couples the two. It can be opened up once a shader outside this module
    /// needs it; the reverse is not a change that can be made.
    let vrm0MaterialProperty: VRM0.MaterialProperty?

    /// The document being loaded, the escape hatch for anything the services
    /// below do not cover.
    public var document: GLTFDocument { loader.document }

    /// Whether the document declares itself undrawable without `name` *and* this
    /// load honors that declaration.
    ///
    /// A shader that degrades gracefully should still throw while this is true:
    /// rendering the approximation is not a degradation the document allows. VRM
    /// loads answer false even for a listed extension, because a VRM renders with
    /// whatever this renderer can build.
    public func enforcesRequiredExtension(_ name: String) -> Bool {
        loader.enforcesRequiredExtension(name)
    }

    /// The UV set the meshes rendering this material carry, decided by the core
    /// glTF material's textures. A shader sampling any other set renders through
    /// this one, since the mesh carries no second UV channel to sample.
    public var selectedTexCoord: Int {
        loader.selectedTexCoord(withMaterialIndex: materialIndex)
    }

    /// The material the loader's built-in Unlit / PBR path would build.
    ///
    /// A shader that only wants to adjust the standard result can build on this
    /// instead of reimplementing the whole path.
    public func standardMaterial() throws -> any Material {
        try loader.standardMaterial(for: self)
    }

    /// The glTF sampler the texture at `index` references, or nil when it uses
    /// the defaults.
    ///
    /// Not public: the raw glTF record, of use only to a shader packing its own
    /// sampler state the way MToon does. Assigning a texture to a material
    /// parameter wants ``materialTexture(withTextureIndex:semantic:)`` instead.
    func gltfSampler(withTextureIndex index: Int) throws -> GLTF.Sampler? {
        try loader.gltfSampler(withTextureIndex: index)
    }

    /// Logs a limitation warning once per loader, deduplicated by `key`.
    /// The message is only built the first time.
    public func logOnce(_ key: String, _ message: @autoclosure () -> String) {
        loader.logOnce(key, message())
    }

    /// What MToon data ``material`` carries, from the `VRMC_materials_mtoon`
    /// extension or the VRM 0.x property, decoded and cached by the loader.
    func mtoonResolution() throws -> MToonMaterialDescriptor.Resolution {
        try loader.mtoonResolution(withMaterialIndex: materialIndex)
    }

    /// The single UV transform this renderer applies for `textures`. The first
    /// UV-accessed texture's wins, logging once when they disagree.
    func selectedUVTransform(for textures: [GLTFSampledTexture]) -> GLTFUVTransform {
        loader.selectedUVTransform(withMaterialIndex: materialIndex, textures: textures)
    }

    /// The decoded texture at `index`, cached per (index, semantic).
    public func texture(withTextureIndex index: Int,
                        semantic: TextureResource.Semantic = .color) throws -> TextureResource {
        try loader.texture(withTextureIndex: index, semantic: semantic)
    }

    /// The RealityKit sampler for the glTF texture at `index`.
    ///
    /// Not public: ``materialTexture(withTextureIndex:semantic:)`` pairs it with
    /// its texture in one step, which is all a material parameter takes.
    func textureSampler(withTextureIndex index: Int) throws -> MaterialParameters.Texture.Sampler {
        try loader.sampler(withTextureIndex: index)
    }

    /// The texture at `index` paired with its sampler, ready to assign to a
    /// material parameter.
    public func materialTexture(withTextureIndex index: Int,
                                semantic: TextureResource.Semantic = .color) throws -> MaterialParameters.Texture {
        try loader.materialTexture(withTextureIndex: index, semantic: semantic)
    }
}

/// The mutable render parameters of one material, as the VRM expression
/// runtime drives them.
///
/// Writes accumulate in the state; the runtime then calls ``prepareFlush()``
/// once and ``apply(to:)`` for every material instance rendering the same glTF
/// material (including additional passes such as outlines).
///
/// A state claims values one at a time: it answers nil / false for a value it
/// does not animate, and the runtime then drives that value through the
/// RealityKit material properties, as it does for a material with no state at
/// all. The defaults below claim nothing, so a state only implements what it
/// animates and the rest keeps working.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public protocol VRMAnimatableMaterialState: AnyObject {
    /// The current value of one bindable color, or nil for a color this state
    /// does not animate. Defaults to nil.
    func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float>?
    /// Records a `materialColorBind` write, answering whether this state
    /// animates that color. Defaults to false.
    func setColor(_ color: SIMD4<Float>,
                  for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Bool
    /// The UV transform the material currently renders with, or nil for a state
    /// that does not animate one. Defaults to nil.
    var textureTransform: MaterialParameterTypes.TextureCoordinateTransform? { get }
    /// Records a `textureTransformBind` write, answering whether this state
    /// animates the UV transform. Defaults to false.
    func setTextureTransform(scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float) -> Bool
    /// Bakes pending writes into whatever ``apply(to:)`` pushes. Returning
    /// false keeps the state dirty, and the runtime retries on its next flush.
    /// Defaults to true, for a state ``apply(to:)`` reads directly.
    func prepareFlush() -> Bool
    /// The material updated to this state, or the material unchanged when it is
    /// not one this state describes.
    func apply(to material: any Material) -> any Material
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public extension VRMAnimatableMaterialState {
    func color(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float>? {
        nil
    }

    func setColor(_ color: SIMD4<Float>,
                  for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Bool {
        false
    }

    var textureTransform: MaterialParameterTypes.TextureCoordinateTransform? { nil }

    func setTextureTransform(scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float) -> Bool { false }

    func prepareFlush() -> Bool { true }
}
#endif
