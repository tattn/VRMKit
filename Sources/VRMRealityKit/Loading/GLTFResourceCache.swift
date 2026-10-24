#if canImport(RealityKit)
import Foundation
import OSLog
import RealityKit
import VRMKit
import VRMKitRuntime

/// What one document resolves to, for as long as a loader holds it.
///
/// Everything here is derived from the document alone, so it belongs to no one load: a
/// second load of the same model reads its meshes, materials and textures from here
/// rather than building them again.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class GLTFResourceCache {
    let document: GLTFDocument
    var gltf: GLTF { document.gltf }
    /// The material shaders a load consults, in order.
    let shaders: [any GLTFMaterialShader]
    let profile: any GLTFAssetProfile
    /// What to render a material the shader chain could not build as, or nil to fail the
    /// load with the shader's error.
    let materialFallback: (@MainActor (GLTFMaterialShaderContext, any Error) -> GLTFShadedMaterial?)?
    /// See ``GLTFEntityLoader/maxTextureDimension``.
    let maxTextureDimension: Int?
    /// See ``GLTFEntityLoader/outputColorSpace``.
    let outputColorSpace: GLTFOutputColorSpace
    /// See ``GLTFEntityLoader/compensatesToneMapping``.
    let compensatesToneMapping: Bool

    static let gltfLogger = Logger(subsystem: "com.github.tattn.VRMKit", category: "glTF")

    init(document: GLTFDocument,
         shaders: [any GLTFMaterialShader],
         profile: any GLTFAssetProfile,
         materialFallback: (@MainActor (GLTFMaterialShaderContext, any Error) -> GLTFShadedMaterial?)? = nil,
         maxTextureDimension: Int? = nil,
         outputColorSpace: GLTFOutputColorSpace = .displayP3,
         compensatesToneMapping: Bool = true) {
        self.document = document
        self.shaders = shaders
        self.profile = profile
        self.materialFallback = materialFallback
        self.maxTextureDimension = maxTextureDimension
        self.outputColorSpace = outputColorSpace
        self.compensatesToneMapping = compensatesToneMapping
        self.skeletons = Array(repeating: nil, count: document.gltf.skins.count)
        self.materials = Array(repeating: nil, count: document.gltf.materials.count)
    }

    // MARK: - Structure

    private var assetReader: GLTFAssetReader?

    /// What reads the document into an asset, with the node graph and skins validated as
    /// it is made. Kept once made: an immutable document does not grow a second answer.
    func reader() throws -> GLTFAssetReader {
        if let assetReader { return assetReader }
        let reader = try GLTFAssetReader(document: document, profile: profile)
        assetReader = reader
        return reader
    }

    /// Who the document's nodes hang off.
    func nodeHierarchy() throws -> GLTFNodeHierarchy {
        try reader().hierarchy
    }

    private var assets: [Int: GLTFAsset] = [:]

    /// The scene at `sceneIndex` read into an asset, from the meshes its build read.
    func asset(sceneIndex: Int) throws -> GLTFAsset {
        if let asset = assets[sceneIndex] { return asset }
        let asset = try reader().asset(sceneIndex: sceneIndex, meshes: assetMeshes)
        assets[sceneIndex] = asset
        return asset
    }

    /// glTF extensions this renderer implements, to satisfy `extensionsRequired`: the
    /// built-in ones, plus whatever the shader chain and the profile claim.
    var supportedRequiredExtensions: Set<String> {
        var extensions: Set<String> = [GLTFExtension.materialsUnlit.rawValue,
                                       GLTFExtension.textureTransform.rawValue]
        for shader in shaders {
            extensions.formUnion(shader.supportedRequiredExtensions)
        }
        return extensions.union(profile.supportedRequiredExtensions)
    }

    /// Whether the document declares itself undrawable without `name`, which tells a
    /// shader to fail a material rather than approximate it.
    func enforcesRequiredExtension(_ name: String) -> Bool {
        gltf.extensionsRequired.contains(name)
    }

    // MARK: - Meshes and skins

    /// The vertex data of every mesh a load has read, by how a node draws it.
    var assetMeshes: [GLTFAssetReader.MeshKey: GLTFAssetReader.BuiltMesh] = [:]

    /// Meshes built once and cloned per node, by every load of the document.
    var meshTemplates: [GLTFAssetReader.MeshKey: Entity] = [:]

    /// Each glTF skin's joints, parents first, as RealityKit poses them.
    var skeletons: [MeshResource.Skeleton?]

    // MARK: - Materials and textures

    /// One glTF material resolved through the shader chain: what it renders as.
    var materials: [GLTFShadedMaterial?]
    var mtoonResolutionCache: [Int: MToonMaterialDescriptor.Resolution] = [:]
    /// Whether each MASK material draws opaque, its cutout discarding nothing
    /// (``GLTFSceneBuilder/drawsCutoutOpaque(materialIndex:)``).
    var cutoutsDrawnOpaque: [Int: Bool] = [:]

    /// One glTF image decoded for one semantic: RealityKit bakes the semantic into the
    /// resource, so an image read as color and as a normal map is two.
    struct ImageTextureKey: Hashable {
        let imageIndex: Int
        let semantic: TextureResource.Semantic
    }

    var textureCache: [ImageTextureKey: TextureResource] = [:]
    /// Metal and roughness split out of one image's channels.
    var metallicRoughnessCache: [Int: (metal: TextureResource, rough: TextureResource)] = [:]
    var bakedTextureCache: [GLTFBakedImageKey: TextureResource] = [:]
    /// MToon's single-channel maps packed into one texture, keyed by the images the red,
    /// green and blue channels come from.
    var mtoonMaskCache: [[Int?]: TextureResource] = [:]
    /// Keyed by glTF sampler index; nil is the texture that names no sampler.
    var samplerCache: [Int?: MaterialParameters.Texture.Sampler] = [:]

    // MARK: - Logging

    private var loggedLimitations: Set<String> = []

    /// Logs a limitation warning once per document, deduplicated by `key`.
    func logOnce(_ key: String, _ message: @autoclosure () -> String) {
        guard loggedLimitations.insert(key).inserted else { return }
        let text = message()
        Self.gltfLogger.warning("\(text, privacy: .public)")
    }
}

/// Reads one of the arrays a document indexes, refusing an index it does not hold.
/// `subject` names what is read, for the message.
func loadCached<T>(_ values: [T], at index: Int, of subject: String) throws -> T {
    guard values.indices.contains(index) else {
        throw VRMError._dataInconsistent(
            "\(subject) \(index) is not one of the document's \(values.count)"
        )
    }
    return values[index]
}
#endif
