import SceneKit
import simd
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNNode: VRMRuntimeNode {
    package typealias RuntimeNode = SCNNode

    package var runtimeParent: SCNNode? { parent }

    package var runtimeChildren: [SCNNode] { childNodes }

    package var localMatrix: simd_float4x4 { simdTransform }

    package var localRotation: simd_quatf { simdOrientation }

    package func setLocalRotation(_ rotation: simd_quatf) {
        simdOrientation = rotation
    }

    package var worldMatrix: simd_float4x4 { simdWorldTransform }

    package var worldRotation: simd_quatf { simdWorldOrientation }
}
