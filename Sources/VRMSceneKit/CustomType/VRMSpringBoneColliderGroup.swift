import VRMKit
import VRMKitRuntime
import SceneKit

/// The colliders of one group, each a shape in the space of the node it hangs
/// off. See `VRMEntitySpringBoneColliderGroup` for the RealityKit twin.
@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
final class VRMSpringBoneColliderGroup {
    private let colliders: [(node: SCNNode, shape: SpringBoneColliderShape)]

    init(colliderGroup: VRM0.SecondaryAnimation.ColliderGroup, loader: VRMSceneLoader) throws {
        let node = try loader.node(withNodeIndex: colliderGroup.node)
        colliders = colliderGroup.colliders.map { (node, SpringBoneColliderShape(vrm0Collider: $0)) }
    }

    init(colliderGroup: VRM1.SpringBone.ColliderGroup,
         springBone: VRM1.SpringBone,
         loader: VRMSceneLoader) throws {
        let sourceColliders = springBone.colliders ?? []
        colliders = try colliderGroup.colliders.compactMap { index in
            guard let collider = sourceColliders[safe: index] else { return nil }
            return (try loader.node(withNodeIndex: collider.node), SpringBoneColliderShape(vrm1Collider: collider))
        }
    }

    /// Where the colliders are now, solved as a spring asks for them.
    func appendWorldColliders(to result: inout [SpringBoneCollider]) {
        for collider in colliders {
            result.append(collider.shape.world(in: collider.node.utx.localToWorldMatrix))
        }
    }
}
