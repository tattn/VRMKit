import VRMKit

public final class Humanoid<Node> {
    package var bones: [HumanoidBone: Node] = [:]
    private var boneIndices: [HumanoidBone: Int] = [:]

    package init() {}

    /// Binds the rig to the nodes it was built from, both VRM versions reading
    /// as the same `boneNodes` mapping.
    package func setUp(boneNodes: [HumanoidBone: Int], nodes: [Node?]) {
        bones = boneNodes.reduce(into: [:]) { result, entry in
            guard nodes.indices.contains(entry.value), let node = nodes[entry.value] else { return }
            result[entry.key] = node
        }
        boneIndices = boneNodes.filter { bones[$0.key] != nil }
    }

    public func node(for bone: HumanoidBone) -> Node? {
        return bones[bone]
    }

    /// The index of the bone's node, as a model's pose names its nodes.
    public func nodeIndex(for bone: HumanoidBone) -> Int? {
        boneIndices[bone]
    }
}
