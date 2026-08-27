import Foundation

/// What a ``GLTFEditableDocument/prune()`` did.
///
/// Pruning renumbers everything it keeps, so an index saved from an earlier
/// edit points at a different entry afterwards, or past the end. Ask this where
/// the old one landed.
public struct GLTFPruneResult: Sendable {
    /// How many BIN bytes the prune reclaimed.
    public let reclaimedByteCount: Int

    /// No entry at all for what the prune dropped.
    private let moved: [GLTFArray: [Int: Int]]

    package init(reclaimedByteCount: Int, moved: [GLTFArray: [Int: Int]]) {
        self.reclaimedByteCount = reclaimedByteCount
        self.moved = moved
    }

    /// Where a node ended up, or nil for one the prune dropped.
    public func newIndex(of node: GLTFNodeIndex) -> GLTFNodeIndex? {
        moved[.nodes]?[node.rawValue].map { GLTFNodeIndex($0) }
    }

    public func newIndex(of mesh: GLTFMeshIndex) -> GLTFMeshIndex? {
        moved[.meshes]?[mesh.rawValue].map { GLTFMeshIndex($0) }
    }

    public func newIndex(of material: GLTFMaterialIndex) -> GLTFMaterialIndex? {
        moved[.materials]?[material.rawValue].map { GLTFMaterialIndex($0) }
    }

    public func newIndex(of scene: GLTFSceneIndex) -> GLTFSceneIndex? {
        moved[.scenes]?[scene.rawValue].map { GLTFSceneIndex($0) }
    }
}
