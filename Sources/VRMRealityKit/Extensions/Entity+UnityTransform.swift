#if canImport(RealityKit)
import RealityKit
import simd
import VRMKitRuntime

extension Entity {
    var utx: UnityTransform<Entity> { UnityTransform(self) }
}

@MainActor
extension UnityTransform where Base == Entity {
    var localRotation: simd_quatf {
        base.transform.rotation
    }

    func setLocalRotation(_ rotation: simd_quatf) {
        base.transform.rotation = rotation
    }

    var position: SIMD3<Float> {
        base.transformMatrix(relativeTo: nil).translation
    }

    var rotation: simd_quatf {
        Transform(matrix: base.transformMatrix(relativeTo: nil)).rotation
    }

    func setRotation(_ rotation: simd_quatf) {
        if let parent = base.parent {
            let parentRotation = Transform(matrix: parent.transformMatrix(relativeTo: nil)).rotation
            base.transform.rotation = simd_inverse(parentRotation) * rotation
        } else {
            base.transform.rotation = rotation
        }
    }

    var localToWorldMatrix: simd_float4x4 {
        base.transformMatrix(relativeTo: nil)
    }

    var worldToLocalMatrix: simd_float4x4 {
        simd_inverse(localToWorldMatrix)
    }

}
#endif
