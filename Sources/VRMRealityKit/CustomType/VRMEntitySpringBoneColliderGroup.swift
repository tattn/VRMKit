#if canImport(RealityKit)
import RealityKit
import VRMKit
import VRMKitRuntime

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class VRMEntitySpringBoneColliderGroup {
    let colliders: [Collider]

    init(colliderGroup: VRM0.SecondaryAnimation.ColliderGroup, loader: GLTFEntityLoader) throws {
        let node = try loader.node(withNodeIndex: colliderGroup.node)
        self.colliders = colliderGroup.colliders.map { Collider(node: node, collider: $0) }
    }

    init(colliderGroup: VRM1.SpringBone.ColliderGroup,
         springBone: VRM1.SpringBone,
         loader: GLTFEntityLoader) throws {
        let sourceColliders = springBone.colliders ?? []
        self.colliders = try colliderGroup.colliders.compactMap { colliderIndex in
            guard sourceColliders.indices.contains(colliderIndex) else { return nil }
            return try Collider(collider: sourceColliders[colliderIndex], loader: loader)
        }
    }

    @MainActor
    final class Collider {
        let node: Entity
        let offset: SIMD3<Float>
        let tail: SIMD3<Float>?
        let radius: Float

        var worldCollider: SpringBoneCollider {
            SpringBoneCollider(head: node.utx.transformPoint(offset),
                               tail: tail.map(node.utx.transformPoint),
                               radius: radius)
        }

        init(node: Entity, collider: VRM0.SecondaryAnimation.ColliderGroup.Collider) {
            self.node = node
            self.offset = collider.offset.simd
            self.tail = nil
            self.radius = Float(collider.radius)
        }

        init(collider: VRM1.SpringBone.Collider, loader: GLTFEntityLoader) throws {
            self.node = try loader.node(withNodeIndex: collider.node)
            if let sphere = collider.shape.sphere {
                self.offset = SIMD3<Float>(sphere.offset, default: .zero)
                self.tail = nil
                self.radius = Float(sphere.radius)
            } else if let capsule = collider.shape.capsule {
                self.offset = SIMD3<Float>(capsule.offset, default: .zero)
                self.tail = SIMD3<Float>(capsule.tail, default: .zero)
                self.radius = Float(capsule.radius)
            } else {
                self.offset = .zero
                self.tail = nil
                self.radius = 0
            }
        }
    }
}
#endif
