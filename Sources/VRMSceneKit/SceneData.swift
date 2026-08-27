import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
final class SceneData {
    /// An `SCNGeometrySource` carries one semantic, so an accessor backing two of them
    /// makes two sources.
    struct GeometrySourceKey: Hashable {
        let accessor: Int
        let semantic: SCNGeometrySource.Semantic
    }

    // Built once and shared: nothing here is posed by the scene drawing it.
    var geometrySources: [GeometrySourceKey: SCNGeometrySource] = [:]
    var textures: [SCNMaterialProperty?]
    var images: [VRMImage?]

    // Rebuilt per scene: a node has one parent and expressions pose the materials, so
    // sharing either would let one scene move another.
    var nodes: [SCNNode?]
    var cameras: [SCNCamera?]
    var materials: [SCNMaterial?]
    /// One mesh node of the scene being built, and the node that draws it: VRM annotates
    /// first person per node, and glTF lets two nodes draw one mesh.
    struct SceneMesh {
        let nodeIndex: Int
        let node: SCNNode
    }

    /// Mesh index -> every node built for it: several nodes may share one glTF mesh
    /// while an `SCNNode` has one parent.
    var meshes: [Int: [SceneMesh]] = [:]
    /// The primitives a first-person camera cuts, keyed by the node drawing each.
    var firstPersonPrimitives: [ObjectIdentifier: FirstPersonPrimitive] = [:]

    init(vrm: GLTF) {
        textures = Array(repeating: nil, count: vrm.textures.count)
        images = Array(repeating: nil, count: vrm.images.count)
        nodes = Array(repeating: nil, count: vrm.nodes.count)
        cameras = Array(repeating: nil, count: vrm.cameras.count)
        materials = Array(repeating: nil, count: vrm.materials.count)
    }

    /// Starts building a scene's node graph, dropping the previous one's objects while
    /// every shared cache stays warm.
    func beginScene() {
        nodes = Array(repeating: nil, count: nodes.count)
        cameras = Array(repeating: nil, count: cameras.count)
        materials = Array(repeating: nil, count: materials.count)
        meshes = [:]
        firstPersonPrimitives = [:]
    }

    func load<T>(_ keyPath: KeyPath<SceneData, [T]>, index: Int) throws -> T {
        let values = self[keyPath: keyPath]
        return try values[safe: index] ??? ._dataInconsistent("\(keyPath): out of index \(index) < \(values.count)")
    }
}

/// The nodes each camera draws one primitive of an `auto` mesh through.
///
/// Two nodes rather than one swapping geometry: an `SCNNode` renders a little
/// differently once its geometry has been reassigned.
@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
struct FirstPersonPrimitive {
    let thirdPerson: SCNNode
    /// Nil when the head draws every triangle, so a first-person camera draws none of it.
    let firstPerson: SCNNode?
}
