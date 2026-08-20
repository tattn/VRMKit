import simd
import VRMKit

package extension SIMD3 where Scalar == Float {
    init(_ values: [Double]?, `default` defaultValue: SIMD3<Float>) {
        self.init(Float(values?[safe: 0] ?? Double(defaultValue.x)),
                  Float(values?[safe: 1] ?? Double(defaultValue.y)),
                  Float(values?[safe: 2] ?? Double(defaultValue.z)))
    }

    init(_ values: [Double], `default` defaultValue: SIMD3<Float>) {
        self.init(Optional(values), default: defaultValue)
    }

    init(_ color: Color3) {
        self.init(color.r, color.g, color.b)
    }

    var normalized: SIMD3 {
        simd_normalize(self)
    }

    var length: Scalar {
        simd_length(self)
    }

    var length_squared: Scalar {
        simd_length_squared(self)
    }

    mutating func normalize() {
        self = normalized
    }
}

package extension SIMD4 where Scalar == Float {
    init(_ values: [Double], `default` defaultAlpha: Float) {
        self.init(Float(values[safe: 0] ?? 0),
                  Float(values[safe: 1] ?? 0),
                  Float(values[safe: 2] ?? 0),
                  Float(values[safe: 3] ?? Double(defaultAlpha)))
    }

    init(_ color: GLTF.Color4) {
        self.init(color.r, color.g, color.b, color.a)
    }

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
    /// The unit quaternion with the same orientation, or identity when the vector
    /// is degenerate. Decoding and interpolation both produce off-unit values.
    var safelyNormalized: simd_quatf {
        let lengthSquared = simd_dot(vector, vector)
        guard lengthSquared > Float.ulpOfOne else { return quat_identity_float }
        return simd_quatf(vector: vector / sqrt(lengthSquared))
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
