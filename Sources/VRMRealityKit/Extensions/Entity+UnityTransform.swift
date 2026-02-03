#if canImport(RealityKit)
import RealityKit
import simd
import VRMKitRuntime

extension Entity: UnityTransformCompatible {}

@MainActor

extension UnityTransform where Base == Entity {
    func transformPoint(_ position: SIMD3<Float>) -> SIMD3<Float> {
        let world = base.transformMatrix(relativeTo: nil)
        return world.multiplyPoint(position)
    }

    func inverseTransformPoint(_ position: SIMD3<Float>) -> SIMD3<Float> {
        let world = base.transformMatrix(relativeTo: nil)
        let inverse = simd_inverse(world)
        return inverse.multiplyPoint(position)
    }

    var localRotation: simd_quatf {
        get { base.transform.rotation }
        set { base.transform.rotation = newValue }
    }

    var position: SIMD3<Float> {
        get { base.transformMatrix(relativeTo: nil).translation }
        set { setWorldPosition(newValue) }
    }

    var localPosition: SIMD3<Float> {
        get { base.transform.translation }
        set { base.transform.translation = newValue }
    }

    var rotation: simd_quatf {
        get { Transform(matrix: base.transformMatrix(relativeTo: nil)).rotation }
        set { setWorldRotation(newValue) }
    }

    var childCount: Int {
        base.children.count
    }

    var localToWorldMatrix: simd_float4x4 {
        base.transformMatrix(relativeTo: nil)
    }

    var worldToLocalMatrix: simd_float4x4 {
        simd_inverse(localToWorldMatrix)
    }

    var lossyScale: SIMD3<Float> {
        Transform(matrix: localToWorldMatrix).scale
    }

    private func setWorldRotation(_ rotation: simd_quatf) {
        if let parent = base.parent {
            let parentRotation = Transform(matrix: parent.transformMatrix(relativeTo: nil)).rotation
            base.transform.rotation = simd_inverse(parentRotation) * rotation
        } else {
            base.transform.rotation = rotation
        }
    }

    private func setWorldPosition(_ position: SIMD3<Float>) {
        if let parent = base.parent {
            let parentWorld = parent.transformMatrix(relativeTo: nil)
            let local = simd_mul(simd_inverse(parentWorld), SIMD4<Float>(position.x, position.y, position.z, 1))
            base.transform.translation = SIMD3<Float>(local.x, local.y, local.z)
        } else {
            base.transform.translation = position
        }
    }
}
#endif
