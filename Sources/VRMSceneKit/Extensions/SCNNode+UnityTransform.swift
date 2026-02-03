import SceneKit
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNNode: UnityTransformCompatible {}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension UnityTransform where Base == SCNNode {
    func transformPoint(_ position: SIMD3<Float>) -> SIMD3<Float> {
        base.simdConvertPosition(position, to: nil)
    }
    
    func inverseTransformPoint(_ position: SIMD3<Float>) -> SIMD3<Float> {
        base.simdConvertPosition(position, from: nil)
    }
    
    var localRotation: simd_quatf {
        get { base.simdOrientation }
        set { base.simdOrientation = newValue }
    }
    
    var position: SIMD3<Float> {
        get { base.simdWorldPosition }
        set { base.simdWorldPosition = newValue }
    }
    
    var localPosition: SIMD3<Float> {
        get { base.simdPosition }
        set { base.simdPosition = newValue }
    }
    
    var rotation: simd_quatf {
        get { base.simdWorldOrientation }
        set { base.simdWorldOrientation = newValue }
    }
    
    var childCount: Int {
        base.childNodes.count
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
    
    var lossyScale: SIMD3<Float> {
        if let parent = base.parent {
            return parent.utx.lossyScale * base.simdScale
        } else {
            return base.simdScale
        }
    }
}
