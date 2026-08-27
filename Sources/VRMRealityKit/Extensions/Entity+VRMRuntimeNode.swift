#if canImport(RealityKit)
import RealityKit
import simd
import VRMKitRuntime

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension Entity: @MainActor VRMRuntimeNode {
    package typealias RuntimeNode = Entity

    package var runtimeParent: Entity? { parent }

    package var runtimeChildren: [Entity] { Array(children) }

    package var localMatrix: simd_float4x4 { transform.matrix }

    package var localRotation: simd_quatf { transform.rotation }

    package func setLocalRotation(_ rotation: simd_quatf) {
        transform.rotation = rotation
    }

    package var worldMatrix: simd_float4x4 { transformMatrix(relativeTo: nil) }

    package var worldRotation: simd_quatf { orientation(relativeTo: nil) }
}
#endif
