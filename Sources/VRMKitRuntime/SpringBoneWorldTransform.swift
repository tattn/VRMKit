import simd
import VRMKit

/// Where a node is in world space.
///
/// The matrix composes exactly, including the shear a non-uniform scale above a
/// rotation produces, which a translation-rotation-scale triple cannot hold. The
/// rotation is composed alongside it as the quaternion product the spring and
/// constraint solvers are written against.
package struct SpringBoneWorldTransform: Sendable {
    package var matrix: simd_float4x4
    package var rotation: simd_quatf

    package static let identity = SpringBoneWorldTransform(matrix: matrix_identity_float4x4,
                                                           rotation: quat_identity_float)

    package init(matrix: simd_float4x4, rotation: simd_quatf) {
        self.matrix = matrix
        self.rotation = rotation
    }

    package var translation: SIMD3<Float> { matrix.translation }
}

/// The rigid move from where a node is at the end of a frame to where it was at a step
/// part of the way through it: a turn about `origin`, landing it on `destination`.
package struct SpringBoneStepMotion: Sendable {
    let rotation: simd_quatf
    let origin: SIMD3<Float>
    let destination: SIMD3<Float>

    static let identity = SpringBoneStepMotion(rotation: quat_identity_float, origin: .zero, destination: .zero)

    private init(rotation: simd_quatf, origin: SIMD3<Float>, destination: SIMD3<Float>) {
        self.rotation = rotation
        self.origin = origin
        self.destination = destination
    }

    /// The move back from `current` to `progress` of the way from `previous`, turning by the
    /// slerped rotation and moving to the mixed position, so the scale and shear stay
    /// `current`'s.
    init(from previous: SpringBoneWorldTransform, to current: SpringBoneWorldTransform, progress: Float) {
        rotation = simd_slerp(previous.rotation, current.rotation, progress) * current.rotation.inverse
        origin = current.translation
        destination = simd_mix(previous.translation, current.translation, SIMD3(repeating: progress))
    }

    /// Moves `transform` along with the node: for what hangs below it.
    func apply(to transform: SpringBoneWorldTransform) -> SpringBoneWorldTransform {
        var matrix = simd_float4x4(rotation) * transform.matrix
        matrix.columns.3 = SIMD4(rotation.act(transform.translation - origin) + destination, 1)
        return SpringBoneWorldTransform(matrix: matrix, rotation: rotation * transform.rotation)
    }
}
