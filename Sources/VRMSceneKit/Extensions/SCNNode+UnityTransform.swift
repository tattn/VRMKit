import SceneKit
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNNode {
    var utx: UnityTransform<SCNNode> { UnityTransform(self) }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension UnityTransform where Base == SCNNode {
    var localRotation: simd_quatf {
        base.simdOrientation
    }

    func setLocalRotation(_ rotation: simd_quatf) {
        base.simdOrientation = rotation
    }
    
    var position: SIMD3<Float> {
        base.simdWorldPosition
    }
    
    var rotation: simd_quatf {
        base.simdWorldOrientation
    }

    func setRotation(_ rotation: simd_quatf) {
        base.simdWorldOrientation = rotation
    }
    
    var localToWorldMatrix: simd_float4x4 {
        if let parent = base.parent {
            return parent.utx.localToWorldMatrix * base.simdTransform
        } else {
            return base.simdTransform
        }
    }
    
    var worldToLocalMatrix: simd_float4x4 {
        localToWorldMatrix.inverse
    }
    
}
