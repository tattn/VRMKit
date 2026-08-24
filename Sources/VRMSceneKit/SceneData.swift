import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
final class SceneData {
    /// An `SCNGeometrySource` carries one semantic, so an accessor backing two
    /// of them makes two sources.
    struct GeometrySourceKey: Hashable {
        let accessor: Int
        let semantic: SCNGeometrySource.Semantic
    }

    var scenes: [VRMScene?]
    var cameras: [SCNCamera?]
    var nodes: [SCNNode?]
    /// Mesh index -> every node built for it, several nodes being free to
    /// share one glTF mesh while an `SCNNode` has one parent.
    var meshes: [Int: [SCNNode]] = [:]
    var geometrySources: [GeometrySourceKey: SCNGeometrySource] = [:]
    var materials: [SCNMaterial?] = []
    var textures: [SCNMaterialProperty?] = []
    var images: [VRMImage?] = []

    init(vrm: GLTF) {
        scenes = Array(repeating: nil, count: vrm.scenes?.count ?? 0)
        cameras = Array(repeating: nil, count: vrm.cameras?.count ?? 0)
        nodes = Array(repeating: nil, count: vrm.nodes?.count ?? 0)
        materials = Array(repeating: nil, count: vrm.materials?.count ?? 0)
        textures = Array(repeating: nil, count: vrm.textures?.count ?? 0)
        images = Array(repeating: nil, count: vrm.images?.count ?? 0)
    }

    func load<T>(_ keyPath: KeyPath<SceneData, [T]>, index: Int) throws -> T {
        let values = self[keyPath: keyPath]
        return try values[safe: index] ??? ._dataInconsistent("\(keyPath): out of index \(index) < \(values.count)")
    }
}
