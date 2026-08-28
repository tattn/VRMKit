import simd
import VRMKit

/// The `VRMC_node_constraint` constraints of one model, in the order they have to
/// be applied. The maths is ``VRMNodeConstraintRuntime``; this reads the
/// constraints off the glTF nodes, orders them so a constraint runs after whatever
/// drives its source, and poses the nodes each frame.
package struct NodeConstraintRig<Node: VRMRuntimeNode> where Node.RuntimeNode == Node {
    private struct Binding {
        let targetIndex: Int
        let descriptor: VRMNodeConstraintDescriptor
        let target: Node
        let source: Node
        let targetRestRotation: simd_quatf
        let sourceRestRotation: simd_quatf
    }

    private var bindings: [Binding] = []

    package init() {}

    /// The constraints the glTF nodes declare, or none for a VRM 0.x model. `node`
    /// resolves a glTF node index to the renderer's node.
    package static func make(vrm: VRM,
                             gltfNodes: [GLTF.Node],
                             hierarchy: GLTFNodeHierarchy,
                             node: (Int) throws -> Node) throws -> NodeConstraintRig<Node> {
        var rig = NodeConstraintRig<Node>()
        guard case .v1 = vrm else { return rig }

        var bindings: [Binding] = []
        for (targetIndex, gltfNode) in gltfNodes.enumerated() {
            guard let constraint = gltfNode.extensions?.nodeConstraint?.constraint else { continue }
            let descriptor = VRMNodeConstraintDescriptor(constraint)
            let sourceIndex = descriptor.source
            guard sourceIndex != targetIndex else {
                throw VRMError._dataInconsistent("VRMC_node_constraint source must not be destination: \(targetIndex)")
            }
            guard gltfNodes.indices.contains(sourceIndex) else {
                throw VRMError._dataInconsistent("VRMC_node_constraint source index is out of range: \(sourceIndex)")
            }

            let target = try node(targetIndex)
            let source = try node(sourceIndex)
            bindings.append(Binding(targetIndex: targetIndex,
                                    descriptor: descriptor,
                                    target: target,
                                    source: source,
                                    targetRestRotation: target.localRotation,
                                    sourceRestRotation: source.localRotation))
        }
        rig.bindings = try orderNodeConstraints(
            bindings,
            targetIndex: { $0.targetIndex },
            dependencies: { $0.descriptor.dependencies(destination: $0.targetIndex, in: hierarchy) }
        )
        return rig
    }

    /// Poses every constrained node and answers whether any of them moved,
    /// which is what tells a renderer its skin pose is stale.
    package func apply() -> Bool {
        var moved = false
        for binding in bindings where apply(binding) {
            moved = true
        }
        return moved
    }

    private func apply(_ binding: Binding) -> Bool {
        let target = binding.target
        let source = binding.source
        let rotation = VRMNodeConstraintRuntime.evaluate(
            binding.descriptor,
            sourceRestRotation: binding.sourceRestRotation,
            sourceLocalRotation: source.localRotation,
            sourceWorldPosition: source.worldPosition,
            destinationRestRotation: binding.targetRestRotation,
            destinationParentWorldRotation: target.runtimeParent?.worldRotation ?? quat_identity_float,
            destinationWorldPosition: target.worldPosition
        )
        return target.setLocalRotationIfMoved(rotation)
    }
}
