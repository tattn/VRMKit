import VRMKit
import VRMKitRuntime
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
final class VRMSpringBoneColliderGroup {
    let colliders: [Collider]
    
    init(colliderGroup: VRM0.SecondaryAnimation.ColliderGroup, loader: VRMSceneLoader) throws {
        let node = try loader.node(withNodeIndex: colliderGroup.node)
        self.colliders = colliderGroup.colliders.map { Collider(node: node, collider: $0) }
    }

    init(colliderGroup: VRM1.SpringBone.ColliderGroup,
         springBone: VRM1.SpringBone,
         loader: VRMSceneLoader) throws {
        let sourceColliders = springBone.colliders ?? []
        self.colliders = try colliderGroup.colliders.compactMap { colliderIndex in
            guard sourceColliders.indices.contains(colliderIndex) else { return nil }
            return try Collider(collider: sourceColliders[colliderIndex], loader: loader)
        }
    }
    
    @available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
    final class Collider {
        let node: SCNNode
        let offset: SIMD3<Float>
        let tail: SIMD3<Float>?
        let radius: Float

        var worldCollider: VRMSpringBone.Collider {
            VRMSpringBone.Collider(head: node.utx.transformPoint(offset),
                                   tail: tail.map(node.utx.transformPoint),
                                   radius: radius)
        }
        
        init(node: SCNNode, collider: VRM0.SecondaryAnimation.ColliderGroup.Collider) {
            self.node = node
            self.offset = collider.offset.simd
            self.tail = nil
            self.radius = Float(collider.radius)
        }

        init(collider: VRM1.SpringBone.Collider, loader: VRMSceneLoader) throws {
            self.node = try loader.node(withNodeIndex: collider.node)
            if let sphere = collider.shape.sphere {
                self.offset = SIMD3<Float>(sphere.offset, defaultValue: .zero)
                self.tail = nil
                self.radius = Float(sphere.radius)
            } else if let capsule = collider.shape.capsule {
                self.offset = SIMD3<Float>(capsule.offset, defaultValue: .zero)
                self.tail = SIMD3<Float>(capsule.tail, defaultValue: .zero)
                self.radius = Float(capsule.radius)
            } else {
                self.offset = .zero
                self.tail = nil
                self.radius = 0
            }
        }
    }
}

private extension SIMD3 where Scalar == Float {
    init(_ values: [Double], defaultValue: SIMD3<Float>) {
        self.init(Float(values[safe: 0] ?? Double(defaultValue.x)),
                  Float(values[safe: 1] ?? Double(defaultValue.y)),
                  Float(values[safe: 2] ?? Double(defaultValue.z)))
    }
}
