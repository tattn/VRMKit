#if canImport(RealityKit)
import RealityKit
import VRMKit
import VRMKitRuntime

/// The colliders of one group, each a shape in the space of the node it hangs
/// off. VRM 0.x hangs a whole group off a single node; VRM 1.0 gives every
/// collider its own.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class VRMEntitySpringBoneColliderGroup {
    private let colliders: [(node: Entity, shape: SpringBoneColliderShape)]

    init(colliderGroup: VRM0.SecondaryAnimation.ColliderGroup, loader: GLTFEntityLoader) throws {
        let node = try loader.node(withNodeIndex: colliderGroup.node)
        colliders = colliderGroup.colliders.map { (node, SpringBoneColliderShape(vrm0Collider: $0)) }
    }

    init(colliderGroup: VRM1.SpringBone.ColliderGroup,
         springBone: VRM1.SpringBone,
         loader: GLTFEntityLoader) throws {
        let sourceColliders = springBone.colliders ?? []
        colliders = try colliderGroup.colliders.compactMap { index in
            guard let collider = sourceColliders[safe: index] else { return nil }
            return (try loader.node(withNodeIndex: collider.node), SpringBoneColliderShape(vrm1Collider: collider))
        }
    }

    /// Where the colliders are now. Solved as a spring asks for them rather than
    /// once a frame, since a spring may swing a node another spring's colliders
    /// hang off, and that one must collide with where they have moved to.
    func appendWorldColliders(to result: inout [SpringBoneCollider]) {
        for collider in colliders {
            result.append(collider.shape.world(in: collider.node.utx.localToWorldMatrix))
        }
    }
}
#endif
