#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit
import VRMKitRuntime

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFSceneBuilder {
    /// Decodes every mesh the scene draws that no load has read yet, so the build pass finds
    /// the vertex data already conditioned. A mesh whose template the loader already holds
    /// is left out, since the build clones the template rather than reading a vertex of it.
    ///
    /// Reading the accessors, triangulating, expanding a flat-shaded primitive, generating a
    /// tangent basis and laying the vertices out for the GPU are the bulk of a load and touch
    /// neither RealityKit nor the scene graph, so they run off this actor.
    func prepareGeometry() async throws {
        let reader = try resources.reader()
        let read = Set(resources.assetMeshes.keys).union(resources.meshTemplates.keys)
        let decoded = try await reader.meshes(for: try drawnMeshes(), excluding: read)
        resources.assetMeshes.merge(decoded) { $1 }
        resources.meshVertices.merge(try await Self.layOut(decoded)) { $1 }
    }

    @concurrent
    private nonisolated static func layOut(_ meshes: [GLTFAssetReader.MeshKey: GLTFAssetReader.BuiltMesh]) async throws
        -> [GLTFAssetReader.MeshKey: GLTFMeshVertices] {
        try await withThrowingTaskGroup(of: (GLTFAssetReader.MeshKey, GLTFMeshVertices).self) { group in
            for (key, built) in meshes {
                group.addTask {
                    try Task.checkCancellation()
                    return (key, GLTFMeshVertices(built.mesh.geometry))
                }
            }
            var vertices: [GLTFAssetReader.MeshKey: GLTFMeshVertices] = [:]
            for try await (key, laidOut) in group {
                vertices[key] = laidOut
            }
            return vertices
        }
    }

    /// The mesh one node draws: what the prepare pass read, or read on the spot for one
    /// it did not reach.
    func assetMesh(_ key: GLTFAssetReader.MeshKey, nodeIndex: Int) throws -> GLTFAssetReader.BuiltMesh {
        if let built = resources.assetMeshes[key] { return built }
        let built = try resources.reader().mesh(key, nodeIndex: nodeIndex)
        resources.assetMeshes[key] = built
        return built
    }

    /// Every mesh this builder's scene draws, at the node drawing it.
    func drawnMeshes() throws -> [GLTFAssetReader.DrawnMesh] {
        try resources.reader().drawnMeshes(sceneIndex: sceneIndex)
    }
}
#endif
