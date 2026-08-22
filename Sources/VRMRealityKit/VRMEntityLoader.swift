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

    public init(vrm: VRM,
                rootDirectory: URL? = nil,
                shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) {
        self.vrm = vrm
        super.init(document: GLTFDocument(binary: vrm.gltf, rootDirectory: rootDirectory),
                   shaders: shaders)
        entityName = vrm.meta.title
    }

    /// Loads a VRM from a file URL.
    ///
    /// - Parameters:
    ///   - url: VRM file location.
    ///   - rootDirectory: Optional base directory for external glTF resources.
    ///   - shaders: The material shader chain; see ``GLTFMaterialShader``.
    public convenience init(withURL url: URL,
                            rootDirectory: URL? = nil,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRMLoader().load(withURL: url),
                  rootDirectory: rootDirectory,
                  shaders: shaders)
    }

    /// Loads a bundled VRM resource.
    public convenience init(named: String,
                            rootDirectory: URL? = nil,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRMLoader().load(named: named),
                  rootDirectory: rootDirectory,
                  shaders: shaders)
    }

    /// Loads a VRM from in-memory data.
    public convenience init(withData data: Data,
                            rootDirectory: URL? = nil,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(vrm: try VRMLoader().load(withData: data),
                  rootDirectory: rootDirectory,
                  shaders: shaders)
    }

    /// Unlike the generic loader, a VRM without a default scene still loads: a
    /// VRM is a single avatar, so its first scene is the one to render.
    override public func loadEntity() throws -> VRMEntity {
        return try loadEntity(withSceneIndex: gltf.scene ?? 0)
    }

    override public func loadEntity(withSceneIndex index: Int) throws -> VRMEntity {
        return try (super.loadEntity(withSceneIndex: index) as? VRMEntity)
            ??? ._dataInconsistent("VRMEntityLoader built a non-VRM root entity")
    }

    public func loadThumbnail() throws -> VRMImage {
        try image(withImageIndex: vrm.thumbnailImageIndex)
    }

    override func makeRootEntity(sceneIndex: Int) -> GLTFEntity {
        VRMEntity(vrm: vrm, document: document, sceneIndex: sceneIndex)
    }

    override func didBuildScene(_ entity: GLTFEntity) throws {
        guard let vrmEntity = entity as? VRMEntity else { return }
        vrmEntity.setUpHumanoid(nodes: entityData.nodes)
        try vrmEntity.setUpBlendShapes(nodes: entityData.nodes, meshes: entityData.sceneMeshes, loader: self)
        vrmEntity.setUpFirstPerson(nodes: entityData.nodes, meshes: entityData.sceneMeshes)
        try vrmEntity.setUpNodeConstraints(gltfNodes: try gltf.load(\.nodes), loader: self)
        try vrmEntity.setUpSpringBones(loader: self)
    }

    /// The VRM extensions this loader implements, on top of the generic glTF ones.
    override public var supportedRequiredExtensions: Set<String> {
        super.supportedRequiredExtensions.union([
            "VRM", "VRMC_vrm", "VRMC_springBone", "VRMC_node_constraint"
        ])
    }

    /// Unlike the generic loader, the VRM path only reports an unimplemented
    /// required extension and renders anyway.
    override func validateRequiredExtensions() throws {
        for name in unsupportedRequiredExtensions() {
            Self.gltfLogger.warning("This VRM requires the \(name, privacy: .public) glTF extension, which this renderer does not implement; rendering anyway.")
        }
    }

    /// A VRM renders with whatever this renderer can build, so `extensionsRequired`
    /// never fails one of its materials either: a shader that would refuse to
    /// approximate draws its approximation here instead of dropping the material
    /// to the default one.
    override func enforcesRequiredExtension(_ name: String) -> Bool { false }

    /// Some VRM meshes split primitives by indices but share the same POSITION
    /// accessor, and only one of them carries the morph targets. SceneKit reuses
    /// the morpher across such primitives, so mimic that by sharing the targets.
    override func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] {
        var targetsByPositionAccessor: [Int: [[GLTF.Mesh.Primitive.AttributeKey: Int]]] = [:]
        for primitive in mesh.primitives {
            guard let targets = primitive.targets, !targets.isEmpty,
                  let positionAccessor = primitive.attributes.rawValue[.POSITION] else { continue }
            if targetsByPositionAccessor[positionAccessor] == nil {
                targetsByPositionAccessor[positionAccessor] = targets
            }
        }
        guard !targetsByPositionAccessor.isEmpty else { return mesh.primitives }

        return mesh.primitives.map { primitive in
            guard primitive.targets?.isEmpty ?? true,
                  let positionAccessor = primitive.attributes.rawValue[.POSITION],
                  let sharedTargets = targetsByPositionAccessor[positionAccessor] else {
                return primitive
            }
            var shared = primitive
            shared.targets = sharedTargets
            return shared
        }
    }

    /// Unlike the generic loader, a VRM whose material this renderer cannot build
    /// still renders, with the default material in its place.
    ///
    /// The fallback is cached like any other resolved material, so the failed
    /// build is not retried and the runtime state comes from what is drawn.
    override func primitiveShadedMaterial(withMaterialIndex index: Int) throws -> GLTFShadedMaterial {
        do {
            return try super.primitiveShadedMaterial(withMaterialIndex: index)
        } catch {
            Self.gltfLogger.error("Failed to build the material \(index, privacy: .public); falling back to the default material: \(String(describing: error), privacy: .public)")
            let shaded = GLTFShadedMaterial(material: defaultMaterial())
            cacheShadedMaterial(shaded, withMaterialIndex: index)
            return shaded
        }
    }

    override func vrm0MaterialProperty(for gltfMaterial: GLTF.Material) -> VRM0.MaterialProperty? {
        guard case .v0(let vrm0) = vrm, let name = gltfMaterial.name else {
            return nil
        }
        return vrm0.materialPropertyNameMap[name]
    }
}
#endif
