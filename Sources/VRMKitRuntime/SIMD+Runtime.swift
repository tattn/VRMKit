import simd

public extension SIMD3 where Scalar == Float {
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

public extension simd_quatf {
    static func * (_ left: simd_quatf, _ right: SIMD3<Float>) -> SIMD3<Float> {
        simd_act(left, right)
    }
}

public let quat_identity_float = simd_quatf(matrix_identity_float4x4)

public func cross(_ left: SIMD3<Float>, _ right: SIMD3<Float>) -> SIMD3<Float> {
    simd_cross(left, right)
}

public func normal(_ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>) -> SIMD3<Float> {
    let e1 = v1 - v0
    let e2 = v2 - v0
    return simd_normalize(simd_cross(e1, e2))
}
