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
