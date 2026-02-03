#if canImport(RealityKit)
import RealityKit
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class VRMEntitySpringBoneColliderGroup {
    let node: Entity
    let colliders: [SphereCollider]

    init(colliderGroup: VRM0.SecondaryAnimation.ColliderGroup, loader: VRMEntityLoader) throws {
        self.node = try loader.node(withNodeIndex: colliderGroup.node)
        self.colliders = colliderGroup.colliders.map(SphereCollider.init)
    }

    final class SphereCollider {
        let offset: SIMD3<Float>
        let radius: Float

        init(collider: VRM0.SecondaryAnimation.ColliderGroup.Collider) {
            self.offset = SIMD3<Float>(Float(collider.offset.x), Float(collider.offset.y), Float(collider.offset.z))
            self.radius = Float(collider.radius)
        }
    }
}
#endif

