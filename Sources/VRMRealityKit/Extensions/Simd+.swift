import simd

extension simd_float4x4 {
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
