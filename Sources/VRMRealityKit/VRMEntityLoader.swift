#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import VRMKit
import VRMKitRuntime

/// Loads a VRM model into a ``VRMEntity``.
///
/// The generic glTF rendering is the same one ``GLTFEntityLoader`` runs, read through
/// ``VRMLoadProfile``; this loader adds the VRM layers on top of the scene it builds:
/// humanoid, expressions, first person, node constraints, spring bones and look-at.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class VRMEntityLoader {
    public let vrm: VRM
    public var document: GLTFDocument { vrm.document }
    /// The material shaders this loader consults, in order.
    public let shaders: [any GLTFMaterialShader]

    private let profile: VRMLoadProfile
    let resources: GLTFResourceCache
    private let queue = GLTFLoadQueue()
    var gltf: GLTF { vrm.document.gltf }

    public init(vrm: VRM,
                shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) {
        self.vrm = vrm
        self.shaders = shaders
        let profile = VRMLoadProfile(vrm: vrm)
        self.profile = profile
        self.resources = GLTFResourceCache(document: vrm.document,
                                           shaders: shaders,
                                           profile: profile)
    }

    /// Loads a VRM from a file URL. External resources resolve relative to its directory.
    public convenience init(withURL url: URL,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRM(withURL: url), shaders: shaders)
    }

    /// Loads a bundled VRM resource.
    public convenience init(named: String,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRM(named: named), shaders: shaders)
    }

    /// Loads a VRM from in-memory data, resolving external resources against `rootDirectory`.
    public convenience init(withData data: Data,
                            rootDirectory: URL? = nil,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRM(data: data, rootDirectory: rootDirectory), shaders: shaders)
    }

    /// The chain ``GLTFEntityLoader`` loads through, MToon included.
    public static var defaultShaders: [any GLTFMaterialShader] { GLTFEntityLoader.defaultShaders }

    /// The glTF and VRM extensions this loader implements, to satisfy `extensionsRequired`.
    public var supportedRequiredExtensions: Set<String> {
        resources.supportedRequiredExtensions
    }

    /// Loads the model. A VRM is a single avatar, so an unnamed default scene is the one
    /// scene it holds.
    public func loadEntity() async throws -> VRMEntity {
        try await loadEntity(withSceneIndex: gltf.defaultSceneIndex())
    }

    /// Loads one scene of the model as its own entity graph.
    ///
    /// Loads run one at a time, so a second call waits rather than discarding the first
    /// one's work. A call cancelled while it waits gives up its place there and then.
    public func loadEntity(withSceneIndex index: Int) async throws -> VRMEntity {
        try await queue.run {
            let root = VRMEntity(vrm: vrm, document: document, sceneIndex: index)
            if let name = vrm.name {
                root.name = name
            }
            let (builder, built) = try await resources.build(into: root)
            try setUpVRM(root, built: built, builder: builder)
            // Skin bindings are registered mid-build, so the rest pose is only solvable
            // once the graph is complete.
            root.flushSkinPose()
            return root
        }
    }

    /// The VRM runtime, hung off the entity graph the glTF build made.
    private func setUpVRM(_ entity: VRMEntity,
                          built: GLTFSceneBuilder.BuiltScene,
                          builder: GLTFSceneBuilder) throws {
        let hierarchy = try resources.nodeHierarchy()
        entity.setUpHumanoid(nodes: built.nodes)
        entity.setUpBlendShapes(nodes: built.nodes, meshes: built.meshes, builder: builder)
        entity.setUpFirstPerson(plan: profile.firstPerson(hierarchy: hierarchy),
                                nodes: built.nodes,
                                meshes: built.meshes)
        try entity.setUpNodeConstraints(gltfNodes: gltf.nodes, hierarchy: hierarchy, builder: builder)
        try entity.setUpSpringBones(builder: builder)
        try entity.setUpLookAt(builder: builder)
    }

    /// The image the model shows itself by.
    ///
    /// Decoded on the spot rather than cached: a thumbnail is drawn by whoever asked for
    /// it, not by the entity graph a load builds.
    public func loadThumbnail() throws -> CGImage {
        try document.image(at: vrm.thumbnailImageIndex.rawValue)
    }
}
#endif
