import simd

/// Shared approximate-equality helpers for float comparisons in tests.
extension Float {
    func isApproximatelyEqual(to other: Float, tolerance: Float = 0.0001) -> Bool {
        abs(self - other) < tolerance
    }
}

extension SIMD where Scalar == Float {
    func isApproximatelyEqual(to other: Self, tolerance: Float = 0.0001) -> Bool {
        indices.allSatisfy { abs(self[$0] - other[$0]) < tolerance }
    }
}

extension simd_float4x4 {
    func isApproximatelyEqual(to other: simd_float4x4, tolerance: Float = 0.0001) -> Bool {
        (0..<4).allSatisfy { self[$0].isApproximatelyEqual(to: other[$0], tolerance: tolerance) }
    }
}
