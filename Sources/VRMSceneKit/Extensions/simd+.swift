import simd
import SceneKit

extension simd_float4x4 {
    func multiplyPoint(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let scn = SCNMatrix4(self)
        #if os(macOS)
        let m11 = Float(scn.m11), m12 = Float(scn.m12), m13 = Float(scn.m13), m14 = Float(scn.m14)
        let m21 = Float(scn.m21), m22 = Float(scn.m22), m23 = Float(scn.m23), m24 = Float(scn.m24)
        let m31 = Float(scn.m31), m32 = Float(scn.m32), m33 = Float(scn.m33), m34 = Float(scn.m34)
        let m41 = Float(scn.m41), m42 = Float(scn.m42), m43 = Float(scn.m43), m44 = Float(scn.m44)
        #else
        let m11 = scn.m11, m12 = scn.m12, m13 = scn.m13, m14 = scn.m14
        let m21 = scn.m21, m22 = scn.m22, m23 = scn.m23, m24 = scn.m24
        let m31 = scn.m31, m32 = scn.m32, m33 = scn.m33, m34 = scn.m34
        let m41 = scn.m41, m42 = scn.m42, m43 = scn.m43, m44 = scn.m44
        #endif
        var vector3 = SIMD3<Float>()
        vector3.x = (m11 * v.x + m21 * v.y + m31 * v.z) + m41
        vector3.y = (m12 * v.x + m22 * v.y + m32 * v.z) + m42
        vector3.z = (m13 * v.x + m23 * v.y + m33 * v.z) + m43
        let num: Float = 1.0 / ((m14 * v.x + m24 * v.y + m34 * v.z) + m44)
        vector3.x *= num
        vector3.y *= num
        vector3.z *= num
        return vector3
    }
}
