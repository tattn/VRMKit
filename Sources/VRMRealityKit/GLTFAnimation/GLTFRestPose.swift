#if canImport(RealityKit)
import RealityKit
import simd
import VRMKit

/// The rest pose a glTF node hierarchy describes before any animation runs, in
/// world space. VRM animation retargeting is defined against it: both the
/// animation's skeleton and a VRM model's humanoid rest in T-pose, and their
/// rest orientations are what re-expresses one's local rotations in the other.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFRestPose {
    private let hierarchy: GLTFNodeHierarchy
    private let worlds: [simd_float4x4]

    /// - Throws: when the nodes describe no hierarchy a model could be built
    ///   from, which a `.vrma` never goes through a scene load to find out.
    init(nodes: [GLTF.Node]) throws {
        let hierarchy = try GLTFNodeHierarchy(nodes: nodes)
        self.hierarchy = hierarchy

        let locals = nodes.map(\.localTransform.matrix)
        var worlds = [simd_float4x4?](repeating: nil, count: nodes.count)
        // The hierarchy is a validated forest, so this recursion terminates.
        func world(at index: Int) -> simd_float4x4 {
            if let cached = worlds[index] { return cached }
            let result = hierarchy.parent(at: index).map { world(at: $0) * locals[index] } ?? locals[index]
            worlds[index] = result
            return result
        }
        // Only a handful of these are ever read, so the matrices are resolved
        // here but decomposed on demand below.
        self.worlds = nodes.indices.map { world(at: $0) }
    }

    func contains(_ index: Int) -> Bool {
        worlds.indices.contains(index)
    }

    func parent(at index: Int) -> Int? {
        hierarchy.parent(at: index)
    }

    /// The node's rest transform in world space, its parents' folded in.
    func worldMatrix(at index: Int) -> simd_float4x4 {
        contains(index) ? worlds[index] : matrix_identity_float4x4
    }

    func parentWorldMatrix(at index: Int) -> simd_float4x4 {
        guard let parent = parent(at: index) else { return matrix_identity_float4x4 }
        return worldMatrix(at: parent)
    }

    func worldRotation(at index: Int) -> simd_quatf {
        contains(index) ? Transform(matrix: worlds[index]).rotation : quat_identity_float
    }

    func parentWorldRotation(at index: Int) -> simd_quatf {
        guard let parent = parent(at: index) else { return quat_identity_float }
        return worldRotation(at: parent)
    }

    func worldPosition(at index: Int) -> SIMD3<Float> {
        contains(index) ? worlds[index].translation : .zero
    }
}
#endif
