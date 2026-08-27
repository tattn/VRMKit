import Foundation

/// The parent of every node of a glTF document, validated as it is built: a child
/// index in range, no node claimed by two parents, and no loop. Everything that
/// walks the nodes upwards reads it, so loading, retargeting and editing all
/// refuse the same broken hierarchies.
package struct GLTFNodeHierarchy {
    /// Node index → parent node index, nil for roots.
    private let parents: [Int?]

    /// A hierarchy of no nodes.
    package static let none = GLTFNodeHierarchy(parents: [])

    private init(parents: [Int?]) {
        self.parents = parents
    }

    package init(nodes: [GLTF.Node]) throws {
        try self.init(childIndices: nodes.map { $0.children ?? [] })
    }

    /// From the children each node names, which is how an edit reads them out
    /// of its JSON without decoding the whole document.
    package init(childIndices: [[Int]]) throws {
        var parents = [Int?](repeating: nil, count: childIndices.count)
        for (index, children) in childIndices.enumerated() {
            for child in children {
                guard parents.indices.contains(child) else {
                    throw VRMError._dataInconsistent(
                        "node \(index) has a child \(child) of \(childIndices.count) nodes"
                    )
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
        for index in parents.indices where !verified.contains(index) {
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
    package func parent(at index: Int) -> Int? {
        parents.indices.contains(index) ? parents[index] : nil
    }

    /// `index` and every node above it, nearest first. Empty for an index
    /// outside the document.
    package func lineage(of index: Int) -> [Int] {
        guard parents.indices.contains(index) else { return [] }
        var lineage = [index]
        while let parent = parents[lineage[lineage.count - 1]] {
            lineage.append(parent)
        }
        return lineage
    }

    /// The nodes from `descendant` up to `ancestor`, both ends included and
    /// `descendant` first, or nil when `ancestor` is not above `descendant`.
    package func path(from ancestor: Int, to descendant: Int) -> [Int]? {
        let lineage = self.lineage(of: descendant)
        guard let end = lineage.firstIndex(of: ancestor) else { return nil }
        return Array(lineage.prefix(through: end))
    }

    /// Rejects the malformed node graphs and skins a loader takes for granted: the
    /// spec guarantees the nodes form a forest and that a skin names at least one
    /// joint, each of them once. Without it a cyclic hierarchy would recurse
    /// forever and a bad joint index would trap.
    package static func validatingStructure(of gltf: GLTF) throws -> GLTFNodeHierarchy {
        let nodes = gltf.nodes ?? []
        let hierarchy = try GLTFNodeHierarchy(nodes: nodes)

        for (index, skin) in (gltf.skins ?? []).enumerated() {
            guard !skin.joints.isEmpty else {
                throw VRMError._dataInconsistent("skin \(index) names no joint")
            }
            var seen: Set<Int> = []
            for joint in skin.joints {
                guard nodes.indices.contains(joint) else {
                    throw VRMError._dataInconsistent("skin \(index) has a joint \(joint) of \(nodes.count) nodes")
                }
                guard seen.insert(joint).inserted else {
                    throw VRMError._dataInconsistent("skin \(index) names node \(joint) as a joint twice")
                }
            }
        }

        return hierarchy
    }

    /// Rejects a scene root that another node already claims as a child, since
    /// attaching it would reparent it and make the graph depend on the order
    /// `scene.nodes` happens to list.
    package func validateSceneRoots(_ roots: [Int], sceneIndex: Int) throws {
        for root in roots {
            if let parent = parent(at: root) {
                throw VRMError._dataInconsistent(
                    "scene \(sceneIndex) names node \(root) as a root, but it is a child of node \(parent)"
                )
            }
        }
    }
}
