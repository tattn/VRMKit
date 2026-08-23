import VRMKit

public final class Humanoid<Node> {
    package var bones: [HumanoidBone: Node] = [:]

    public init() {}

    /// Binds the rig to the nodes it was built from, both VRM versions reading
    /// as the same `boneNodes` mapping.
    package func setUp(boneNodes: [HumanoidBone: Int], nodes: [Node?]) {
        bones = boneNodes.reduce(into: [:]) { result, entry in
            guard nodes.indices.contains(entry.value), let node = nodes[entry.value] else { return }
            result[entry.key] = node
        }
    }

    public func node(for bone: HumanoidBone) -> Node? {
        return bones[bone]
    }
}
