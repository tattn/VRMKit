import SceneKit
extension SCNMatrix4 {
    var array: [SCNFloat] {
        [
            m11,
            m12,
            m13,
            m14,
            m21,
            m22,
            m23,
            m24,
            m31,
            m32,
            m33,
            m34,
            m41,
            m42,
            m43,
            m44
        ]
    }
}
