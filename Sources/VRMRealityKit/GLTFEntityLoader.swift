#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

/// Loads a plain glTF / GLB document into a RealityKit entity graph.
///
/// One loader holds one document. Every load builds a new entity graph while reusing the
/// meshes, materials and textures the loads before it resolved, so loading the same scene
/// twice reads no vertex twice.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class GLTFEntityLoader {
    public let document: GLTFDocument
    /// The material shaders this loader consults, in order. Materials no shader claims
    /// render through the built-in Unlit / PBR path, so pass `[]` for that everywhere.
    public let shaders: [any GLTFMaterialShader]

    let resources: GLTFResourceCache
    private let queue = GLTFLoadQueue()
    var gltf: GLTF { document.gltf }

    /// MToon for materials that carry MToon data. Computed so every loader gets its own
    /// shader instances.
    public static var defaultShaders: [any GLTFMaterialShader] { [MToonShader()] }

    /// The largest side a texture keeps, or nil to upload every image as authored.
    ///
    /// There is no default limit: how large a texture is ever drawn is the app's question,
    /// not the document's. Setting one trades sharpness for GPU memory — a 4096x4096 RGBA
    /// image costs about 85 MB with its mipmaps, and models routinely carry several.
    public let maxTextureDimension: Int?

    public init(document: GLTFDocument,
                shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders,
                maxTextureDimension: Int? = nil) {
        self.document = document
        self.shaders = shaders
        self.maxTextureDimension = maxTextureDimension
        self.resources = GLTFResourceCache(document: document,
                                           shaders: shaders,
                                           profile: GLTFDefaultLoadProfile(),
                                           maxTextureDimension: maxTextureDimension)
    }

    /// Loads a `.glb` / `.gltf` file. External resources resolve relative to its directory.
    public convenience init(withURL url: URL,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders,
                            maxTextureDimension: Int? = nil) throws {
        self.init(document: try GLTFDocument(withURL: url), shaders: shaders,
                  maxTextureDimension: maxTextureDimension)
    }

    /// Loads a bundled glTF resource.
    public convenience init(named: String,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders,
                            maxTextureDimension: Int? = nil) throws {
        self.init(document: try GLTFDocument(named: named), shaders: shaders,
                  maxTextureDimension: maxTextureDimension)
    }

    /// Loads in-memory glTF data, resolving external resources against `rootDirectory`.
    public convenience init(withData data: Data,
                            rootDirectory: URL? = nil,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders,
                            maxTextureDimension: Int? = nil) throws {
        self.init(document: try GLTFDocument(data: data, rootDirectory: rootDirectory),
                  shaders: shaders, maxTextureDimension: maxTextureDimension)
    }

    /// glTF extensions this loader implements, to satisfy `extensionsRequired`.
    public var supportedRequiredExtensions: Set<String> {
        resources.supportedRequiredExtensions
    }

    /// Loads the document's default scene, decoding its primitives concurrently off the
    /// actor the entity graph is built on.
    ///
    /// - Throws: when the glTF holds several scenes and names no default one.
    ///   Pick one with ``loadEntity(withSceneIndex:)``.
    public func loadEntity() async throws -> GLTFEntity {
        try await loadEntity(withSceneIndex: gltf.defaultSceneIndex())
    }

    /// Loads one scene of the glTF as its own entity graph.
    ///
    /// Loads run one at a time, so a second call waits rather than discarding the first
    /// one's work. A call cancelled while it waits gives up its place there and then.
    public func loadEntity(withSceneIndex index: Int) async throws -> GLTFEntity {
        try await queue.run {
            let root = GLTFEntity(document: document, sceneIndex: index)
            _ = try await resources.build(into: root)
            root.flushSkinPose()
            return root
        }
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFResourceCache {
    /// Builds the scene `root` names into it, and hands back what the build made of the
    /// document for whoever sets the root up beyond the glTF core.
    func build(into root: GLTFEntity) async throws -> (GLTFSceneBuilder, GLTFSceneBuilder.BuiltScene) {
        let builder = GLTFSceneBuilder(resources: self, root: root)
        try builder.validateDocument()
        try await builder.prepare()
        return (builder, try builder.build())
    }
}
#endif
