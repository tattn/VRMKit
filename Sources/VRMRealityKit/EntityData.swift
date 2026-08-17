#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
final class EntityData {
    /// Loaded scenes, keyed by scene index. Each one owns its entity graph.
    var entities: [VRMEntity?]
    // `nodes` / `meshes` hold Entity *instances*, which belong to a single
    // scene, so `beginScene()` clears them between loads. Every other cache
    // below holds values or GPU resources that are safe to share.
    var nodes: [Entity?]
    var skins: [MeshResource.Skeleton?]
    var skinJointRemaps: [[Int]?]
    var meshes: [Entity?]
    var accessors: [Any?]
    var bufferViews: [Data?] = []
    var materials: [Material?] = []
    var textures: [TextureResource?] = []
    var images: [VRMImage?] = []

    init(vrm: GLTF) {
        entities = Array(repeating: nil, count: vrm.scenes?.count ?? 0)
        nodes = Array(repeating: nil, count: vrm.nodes?.count ?? 0)
        skins = Array(repeating: nil, count: vrm.skins?.count ?? 0)
        skinJointRemaps = Array(repeating: nil, count: vrm.skins?.count ?? 0)
        meshes = Array(repeating: nil, count: vrm.meshes?.count ?? 0)
        accessors = Array(repeating: nil, count: vrm.accessors?.count ?? 0)
        bufferViews = Array(repeating: nil, count: vrm.bufferViews?.count ?? 0)
        materials = Array(repeating: nil, count: vrm.materials?.count ?? 0)
        textures = Array(repeating: nil, count: vrm.textures?.count ?? 0)
        images = Array(repeating: nil, count: vrm.images?.count ?? 0)
    }

    /// Starts building a scene's entity graph, dropping the entity caches while
    /// buffer views, accessors, materials, textures and skeletons stay warm.
    func beginScene() {
        nodes = Array(repeating: nil, count: nodes.count)
        meshes = Array(repeating: nil, count: meshes.count)
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
