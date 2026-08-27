#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
final class EntityData {
    // `nodes` / `sceneMeshes` hold the entities of the scene being built, so
    // `beginScene()` clears them between loads. Every other cache below is shareable.
    var nodes: [Entity?]
    /// One mesh entity of the scene being built, and the node that draws it: VRM
    /// annotates first person per node, and glTF lets two nodes draw one mesh.
    struct SceneMesh {
        let nodeIndex: Int
        let entity: Entity
    }

    /// glTF mesh index → the entities of this scene built from it, one per node.
    var sceneMeshes: [Int: [SceneMesh]] = [:]
    /// One glTF mesh as rendered through one skin, cut for a first-person camera or not.
    /// A mesh used by both a skinned and an unskinned node, or drawn by two nodes VRM
    /// annotates differently, needs one template each.
    struct MeshTemplateKey: Hashable {
        let meshIndex: Int
        let skinIndex: Int?
        let cutsHead: Bool
    }

    /// Meshes built once and cloned per node.
    var meshTemplates: [MeshTemplateKey: Entity] = [:]
    /// One glTF skin resolved for RealityKit.
    struct Skin {
        let skeleton: MeshResource.Skeleton
        /// glTF joint index → its index in ``skeleton``, which orders joints parents-first.
        let jointIndexRemap: [Int]
    }

    var skins: [Skin?]
    /// One glTF material resolved through the shader chain: what it renders as.
    var materials: [GLTFShadedMaterial?] = []
    var images: [CGImage?] = []
    /// Vertex data conditioned for the renderer, filled by a parallel prepare pass and
    /// read by the build pass. Nil for a primitive this renderer draws nothing of.
    var primitiveGeometries: [PrimitiveGeometryKey: GLTFPrimitiveGeometry?] = [:]
    /// Resolved once: what it reads off the materials and skins does not change while
    /// a document is loaded.
    var geometryDecoder: GLTFGeometryDecoder?

    init(gltf: GLTF) {
        nodes = Array(repeating: nil, count: gltf.nodes.count)
        skins = Array(repeating: nil, count: gltf.skins.count)
        materials = Array(repeating: nil, count: gltf.materials.count)
        images = Array(repeating: nil, count: gltf.images.count)
    }

    /// Starts building a scene's entity graph, dropping the previous one's entities
    /// while every shared cache stays warm.
    func beginScene() {
        nodes = Array(repeating: nil, count: nodes.count)
        sceneMeshes = [:]
    }

    /// Drops the decoded images once the build has turned them into texture resources,
    /// which would otherwise be a CPU-side copy of every texture.
    func clearDecodedImages() {
        images = Array(repeating: nil, count: images.count)
    }

    enum EntityDataError: Error {
        case outOfRange(keyPath: String, index: Int, count: Int)
    }

    func load<T>(_ keyPath: KeyPath<EntityData, [T]>, index: Int) throws -> T {
        let values = self[keyPath: keyPath]
        guard values.indices.contains(index) else {
            throw EntityDataError.outOfRange(keyPath: String(describing: keyPath), index: index, count: values.count)
        }
        return values[index]
    }
}
#endif
