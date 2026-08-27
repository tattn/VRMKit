#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit
import VRMKitRuntime

/// Loads a VRM model into a ``VRMEntity``.
///
/// The generic glTF rendering lives in ``GLTFEntityLoader``; this subclass adds
/// the VRM layers on top: VRM 0.x material properties, humanoid, expressions,
/// first person, node constraints and spring bones.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public class VRMEntityLoader: GLTFEntityLoader {
    public let vrm: VRM
    /// Which meshes a first-person camera cuts, read by every mesh the load builds.
    private var firstPersonPlan: VRMFirstPersonPlan?

    public init(vrm: VRM,
                shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) {
        self.vrm = vrm
        super.init(document: vrm.document, shaders: shaders)
        entityName = vrm.name
    }

    /// Loads a VRM from a file URL. External resources resolve relative to the
    /// file's directory.
    ///
    /// - Parameters:
    ///   - url: VRM file location.
    ///   - shaders: The material shader chain; see ``GLTFMaterialShader``.
    public convenience init(withURL url: URL,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRM(withURL: url), shaders: shaders)
    }

    /// Loads a bundled VRM resource.
    public convenience init(named: String,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRM(named: named), shaders: shaders)
    }

    /// Loads a VRM from in-memory data. `rootDirectory` is the base directory
    /// for external glTF resources.
    public convenience init(withData data: Data,
                            rootDirectory: URL? = nil,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRM(data: data, rootDirectory: rootDirectory), shaders: shaders)
    }

    /// Overridden only to narrow the return type: a VRM is a single avatar, so
    /// the default scene it leaves unnamed is the one scene it holds.
    override public func loadEntity() async throws -> VRMEntity {
        try await loadEntity(withSceneIndex: gltf.defaultSceneIndex())
    }

    override public func loadEntity(withSceneIndex index: Int) async throws -> VRMEntity {
        try await (super.loadEntity(withSceneIndex: index) as? VRMEntity)
            ??? ._dataInconsistent("the loaded entity is not a VRMEntity")
    }

    /// The image the model shows itself by, wrapped as the platform image a
    /// caller puts in a view.
    public func loadThumbnail() throws -> VRMImage {
        VRMImage(cgImage: try image(withImageIndex: vrm.thumbnailImageIndex))
    }

    override func makeRootEntity(sceneIndex: Int) -> GLTFEntity {
        VRMEntity(vrm: vrm, document: document, sceneIndex: sceneIndex)
    }

    override func didBuildScene(_ entity: GLTFEntity) throws {
        guard let vrmEntity = entity as? VRMEntity else { return }
        vrmEntity.setUpHumanoid(nodes: entityData.nodes)
        try vrmEntity.setUpBlendShapes(nodes: entityData.nodes, meshes: entityData.sceneMeshes, loader: self)
        vrmEntity.setUpFirstPerson(plan: firstPerson(), nodes: entityData.nodes, meshes: entityData.sceneMeshes)
        try vrmEntity.setUpNodeConstraints(gltfNodes: try gltf.load(\.nodes),
                                           hierarchy: nodeHierarchy ?? .none,
                                           loader: self)
        try vrmEntity.setUpSpringBones(loader: self)
    }

    /// The VRM extensions this loader implements, on top of the generic glTF ones.
    override public var supportedRequiredExtensions: Set<String> {
        super.supportedRequiredExtensions.union([
            GLTFExtension.vrm0.rawValue, GLTFExtension.vrm1.rawValue,
            GLTFExtension.springBone.rawValue, GLTFExtension.nodeConstraint.rawValue,
        ])
    }

    /// Unlike the generic loader, the VRM path only reports an unimplemented
    /// required extension and renders anyway.
    override func validateRequiredExtensions() throws {
        for name in unsupportedRequiredExtensions() {
            Self.gltfLogger.warning("This VRM requires the \(name, privacy: .public) glTF extension, which this renderer does not implement; rendering anyway.")
        }
    }

    /// A VRM renders with whatever this renderer can build, so a shader that would
    /// refuse to approximate draws its approximation instead.
    override func enforcesRequiredExtension(_ name: String) -> Bool { false }

    override func firstPersonHeadJoints(ofNodeAt nodeIndex: Int, meshIndex: Int, skinIndex: Int?) -> Set<UInt32> {
        firstPerson().headJoints(ofNodeAt: nodeIndex, meshIndex: meshIndex, skinIndex: skinIndex)
    }

    private func firstPerson() -> VRMFirstPersonPlan {
        if let firstPersonPlan { return firstPersonPlan }
        // Validated before the first mesh is built, so it is there when asked for.
        let plan = VRMFirstPersonPlan(vrm: vrm, gltf: gltf, hierarchy: nodeHierarchy ?? .none)
        firstPersonPlan = plan
        return plan
    }

    /// A primitive carrying no morph targets of its own morphs with those of
    /// whichever primitive of the mesh carries them for its POSITION accessor.
    override func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] {
        let shared = mesh.morphTargetsByPositionAccessor()
        guard !shared.isEmpty else { return mesh.primitives }
        return mesh.primitives.map { primitive in
            guard primitive.targets?.isEmpty ?? true,
                  let position = primitive.attributes[.POSITION],
                  let targets = shared[position] else {
                return primitive
            }
            var primitive = primitive
            primitive.targets = targets
            return primitive
        }
    }

    /// Unlike the generic loader, a VRM whose material this renderer cannot shade
    /// still renders, with the default material in its place. What the document
    /// itself gets wrong still fails the load: only the shading falls back.
    override func shadedMaterialFallback(for context: GLTFMaterialShaderContext,
                                         error: any Error) -> GLTFShadedMaterial? {
        Self.gltfLogger.error("Failed to build the material \(context.materialIndex, privacy: .public); falling back to the default material: \(String(describing: error), privacy: .public)")
        return GLTFShadedMaterial(material: defaultMaterial())
    }

    override func vrm0MaterialProperty(atMaterialIndex index: Int) -> VRM0.MaterialProperty? {
        vrm.vrm0MaterialProperty(at: index)
    }
}
#endif
