import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
final class VRMSpringBoneColliderGroup {
    let node: SCNNode
    let colliders: [SphereCollider]
    
    init(colliderGroup: VRM0.SecondaryAnimation.ColliderGroup, loader: VRMSceneLoader) throws {
        self.node = try loader.node(withNodeIndex: colliderGroup.node)
        self.colliders = colliderGroup.colliders.map(SphereCollider.init)
    }
    
    @available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
    final class SphereCollider {
        let offset: SIMD3<Float>
        let radius: Float
        
        init(collider: VRM0.SecondaryAnimation.ColliderGroup.Collider) {
            self.offset = collider.offset.simd
            self.radius = Float(collider.radius)
        }
    }
}
