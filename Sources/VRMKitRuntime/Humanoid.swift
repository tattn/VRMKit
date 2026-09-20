import VRMKit

public final class Humanoid<Node> {
    package var bones: [HumanoidBone: Node] = [:]

    public init() {}

    /// Binds the rig to the nodes it was built from, both VRM versions reading
    /// as the same `boneNodes` mapping.
    package func setUp(boneNodes: [HumanoidBone: Int], nodes: [Node?]) throws {
        bones = try boneNodes.reduce(into: [:]) { result, entry in
            guard nodes.indices.contains(entry.value) else {
                throw VRMError._dataInconsistent(
                    "humanoid bone \(entry.key.rawValue) names node \(entry.value), which does not exist"
                )
            }
            guard let node = nodes[entry.value] else { return }
            result[entry.key] = node
        }
    }

    public func node(for bone: HumanoidBone) -> Node? {
        return bones[bone]
    }
}
