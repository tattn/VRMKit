//
//  simd+.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2020/02/16.
//  Copyright © 2020 tattn. All rights reserved.
//

import simd
import SceneKit

extension SIMD3 where Scalar == Float {
    var normalized: SIMD3 {
        simd_normalize(self)
    }
    
    var length: Scalar {
        simd_length(self)
    }
    
    var length_squared: Scalar {
        simd_length_squared(self)
    }
}

extension simd_float4x4 {
    func multiplyPoint(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let scn = SCNMatrix4(self)
        var vector3: SIMD3<Float> = SIMD3<Float>()
        vector3.x = (scn.m11 * v.x + scn.m21 * v.y + scn.m31 * v.z) + scn.m41
        vector3.y = (scn.m12 * v.x + scn.m22 * v.y + scn.m32 * v.z) + scn.m42
        vector3.z = (scn.m13 * v.x + scn.m23 * v.y + scn.m33 * v.z) + scn.m43
        let num: Float = 1.0 / ((scn.m14 * v.x + scn.m24 * v.y + scn.m34 * v.z) + scn.m44)
        vector3.x *= num
        vector3.y *= num
        vector3.z *= num
        return vector3
    }
}

extension simd_quatf {
    static func * (_ left: simd_quatf, _ right: SIMD3<Float>) -> SIMD3<Float> {
        simd_act(left, right)
    }
}
var quart_identity_float = simd_quatf(matrix_identity_float4x4)
