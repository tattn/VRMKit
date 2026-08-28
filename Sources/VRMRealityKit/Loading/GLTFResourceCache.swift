#if canImport(RealityKit)
import Foundation
import OSLog
import RealityKit
import VRMKit

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
    let profile: any GLTFLoadProfile

    static let gltfLogger = Logger(subsystem: "dev.tattn.VRMKit", category: "glTF")

    init(document: GLTFDocument,
         shaders: [any GLTFMaterialShader],
         profile: any GLTFLoadProfile) {
        self.document = document
        self.shaders = shaders
        self.profile = profile
        self.skins = Array(repeating: nil, count: document.gltf.skins.count)
        self.materials = Array(repeating: nil, count: document.gltf.materials.count)
    }

    // MARK: - Structure

    private var validatedNodeHierarchy: GLTFNodeHierarchy?

    /// Who the document's nodes hang off, with the node graph and skins validated as it
    /// is built. Kept once built: an immutable document does not grow a second answer.
    func nodeHierarchy() throws -> GLTFNodeHierarchy {
        if let validatedNodeHierarchy { return validatedNodeHierarchy }
        let hierarchy = try GLTFNodeHierarchy.validatingStructure(of: gltf)
        validatedNodeHierarchy = hierarchy
        return hierarchy
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

    /// One glTF mesh as rendered through one skin, cut for a first-person camera or not.
    /// A mesh used by both a skinned and an unskinned node, or drawn by two nodes VRM
    /// annotates differently, needs one template each.
    struct MeshTemplateKey: Hashable {
        let meshIndex: Int
        let skinIndex: Int?
        let cutsHead: Bool
    }

    /// Meshes built once and cloned per node, by every load of the document.
    var meshTemplates: [MeshTemplateKey: Entity] = [:]

    /// One glTF skin resolved for RealityKit.
    struct Skin {
        let skeleton: MeshResource.Skeleton
        /// glTF joint index → its index in ``skeleton``, which orders joints parents-first.
        let jointIndexRemap: [Int]
    }

    var skins: [Skin?]
    var morphTargetCounts: [Int: Int] = [:]

    // MARK: - Materials and textures

    /// One glTF material resolved through the shader chain: what it renders as.
    var materials: [GLTFShadedMaterial?]
    /// The UV set each material is sampled through, and whether its textures disagree.
    var materialTexCoordCache: [Int: (selected: Int, isMixed: Bool)] = [:]
    var mtoonResolutionCache: [Int: MToonMaterialDescriptor.Resolution] = [:]

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
