#if canImport(RealityKit)
import VRMKit

/// The parent of every node of a glTF document, validated as it is built: a
/// child index in range, no node claimed by two parents, and no loop.
///
/// Everything that walks the nodes upwards reads it, so a model to load and an
/// animation to retarget reject the same broken hierarchies.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFNodeHierarchy {
    /// Node index → parent node index, nil for roots.
    private let parents: [Int?]

    init(nodes: [GLTF.Node]) throws {
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            for child in node.children ?? [] {
                guard nodes.indices.contains(child) else {
                    throw VRMError._dataInconsistent("node \(index) has a child \(child) of \(nodes.count) nodes")
                }
                guard parents[child] == nil else {
                    throw VRMError._dataInconsistent("node \(child) is a child of more than one node")
                }
                parents[child] = index
            }
        }
        // With at most one parent each, the hierarchy is a forest unless walking
        // up from a node returns to a node already on the way up.
        var verified: Set<Int> = []
        for index in nodes.indices where !verified.contains(index) {
            var chain: Set<Int> = []
            var current = index
            while !verified.contains(current) {
                guard chain.insert(current).inserted else {
                    throw VRMError._dataInconsistent("the node hierarchy is cyclic at node \(current)")
                }
                guard let parent = parents[current] else { break }
                current = parent
            }
            verified.formUnion(chain)
        }

        self.parents = parents
    }

    /// The node's parent, nil for a root or an index outside the document.
    func parent(at index: Int) -> Int? {
        parents.indices.contains(index) ? parents[index] : nil
    }
}
#endif
