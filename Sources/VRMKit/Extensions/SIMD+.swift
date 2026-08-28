import simd

package extension SIMD3 where Scalar == Float {
    init(_ values: [Double]?, `default` defaultValue: SIMD3<Float>) {
        self.init(Float(values?[safe: 0] ?? Double(defaultValue.x)),
                  Float(values?[safe: 1] ?? Double(defaultValue.y)),
                  Float(values?[safe: 2] ?? Double(defaultValue.z)))
    }

    var normalized: SIMD3 {
        simd_normalize(self)
    }

    var length_squared: Scalar {
        simd_length_squared(self)
    }
}

package extension SIMD4 where Scalar == Float {
    init(_ values: [Double]?, `default` defaultValue: SIMD4<Float>) {
        guard let values else {
            self = defaultValue
            return
        }
        self.init(Float(values[safe: 0] ?? Double(defaultValue.x)),
                  Float(values[safe: 1] ?? Double(defaultValue.y)),
                  Float(values[safe: 2] ?? Double(defaultValue.z)),
                  Float(values[safe: 3] ?? Double(defaultValue.w)))
    }
}

package extension SIMD2 where Scalar == Float {
    init(_ values: [Double]?, `default` defaultValue: Float) {
        self.init(Float(values?[safe: 0] ?? Double(defaultValue)),
                  Float(values?[safe: 1] ?? Double(defaultValue)))
    }
}

package extension simd_quatf {
    /// The unit quaternion with the same orientation, or identity when the
    /// vector holds no orientation at all. Decoding and interpolation both
    /// produce off-unit values, and writing glTF needs unit ones.
    ///
    /// Dividing by the largest component first is what lets a quaternion far
    /// from unit length keep its orientation: squaring the components of one as
    /// small as `(1e-4, 0, 0, 1e-4)`, or as large as `(1e30, 0, 0, 0)`, loses it
    /// to underflow or overflow.
    var safelyNormalized: simd_quatf {
        guard vector.x.isFinite, vector.y.isFinite,
              vector.z.isFinite, vector.w.isFinite else { return quat_identity_float }
        let largest = simd_abs(vector).max()
        guard largest > 0 else { return quat_identity_float }
        return simd_quatf(vector: simd_normalize(vector / largest))
    }

    static func * (_ left: simd_quatf, _ right: SIMD3<Float>) -> SIMD3<Float> {
        simd_act(left, right)
    }
}

package let quat_identity_float = simd_quatf(matrix_identity_float4x4)

package extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    func multiplyPoint(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let result = simd_mul(self, SIMD4<Float>(v.x, v.y, v.z, 1))
        guard result.w != 0 else {
            return SIMD3<Float>(result.x, result.y, result.z)
        }
        return SIMD3<Float>(result.x / result.w, result.y / result.w, result.z / result.w)
    }
}
