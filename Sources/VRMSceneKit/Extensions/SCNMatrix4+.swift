//
//  SCNMatrix4+.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2019/12/28.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit

extension SCNMatrix4 {
    func multiplyPoint(_ point: SCNVector3) -> SCNVector3 {
        SCNMatrix4MultiplyVector3(self, point)
    }
}

@inlinable func SCNMatrix4MultiplyVector3(_ matrixLeft: SCNMatrix4, _ vectorRight: SCNVector3) -> SCNVector3 {
    let v4 = SCNMatrix4MultiplyVector4(matrixLeft, SCNVector4Make(vectorRight.x, vectorRight.y, vectorRight.z, 0.0))
    return SCNVector3Make(v4.x, v4.y, v4.z)
}

@inlinable func SCNMatrix4MultiplyVector4(_ matrixLeft: SCNMatrix4, _ vectorRight: SCNVector4) -> SCNVector4 {
    let v = SCNVector4(
        matrixLeft.m11 * vectorRight.x + matrixLeft.m21 * vectorRight.y + matrixLeft.m31 * vectorRight.z + matrixLeft.m41 * vectorRight.w,
        matrixLeft.m12 * vectorRight.x + matrixLeft.m22 * vectorRight.y + matrixLeft.m32 * vectorRight.z + matrixLeft.m42 * vectorRight.w,
        matrixLeft.m13 * vectorRight.x + matrixLeft.m23 * vectorRight.y + matrixLeft.m33 * vectorRight.z + matrixLeft.m43 * vectorRight.w,
        matrixLeft.m14 * vectorRight.x + matrixLeft.m24 * vectorRight.y + matrixLeft.m34 * vectorRight.z + matrixLeft.m44 * vectorRight.w
    )
    return v
}
