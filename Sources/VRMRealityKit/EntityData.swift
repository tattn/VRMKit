#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
final class EntityData {
    // `nodes` / `sceneMeshes` hold the Entity *instances* of the scene being
    // built, so `beginScene()` clears them between loads. Every other cache below
    // holds values, GPU resources or clone templates, which are safe to share.
    var nodes: [Entity?]
    /// glTF mesh index → the entities of this scene built from it, one per node.
    var sceneMeshes: [Int: [Entity]] = [:]
    /// One glTF mesh as rendered through one skin. A mesh used by both a skinned
    /// and an unskinned node needs one template each.
    struct MeshTemplateKey: Hashable {
        let meshIndex: Int
        let skinIndex: Int?
    }

    /// Meshes built once and cloned per node.
    var meshTemplates: [MeshTemplateKey: Entity] = [:]
    /// One glTF skin resolved for RealityKit.
    struct Skin {
        let skeleton: MeshResource.Skeleton
        /// glTF joint index → its index in ``skeleton``, which orders the joints
        /// parents-first.
        let jointIndexRemap: [Int]
    }

    var skins: [Skin?]
    var materials: [Material?] = []
    var images: [VRMImage?] = []

    init(gltf: GLTF) {
        nodes = Array(repeating: nil, count: gltf.nodes?.count ?? 0)
        skins = Array(repeating: nil, count: gltf.skins?.count ?? 0)
        materials = Array(repeating: nil, count: gltf.materials?.count ?? 0)
        images = Array(repeating: nil, count: gltf.images?.count ?? 0)
    }

    /// Starts building a scene's entity graph, dropping the entities of the
    /// previous one while every shared cache stays warm.
    func beginScene() {
        nodes = Array(repeating: nil, count: nodes.count)
        sceneMeshes = [:]
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
