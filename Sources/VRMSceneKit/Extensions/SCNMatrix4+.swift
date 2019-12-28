//
//  SCNMatrix4+.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2019/12/28.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit

extension SCNMatrix4 {
    @inlinable func multiplyPoint(_ point: SCNVector3) -> SCNVector3 {
        let v4 = self.multiplyPoint(SCNVector4Make(point.x, point.y, point.z, 0.0))
        return SCNVector3Make(v4.x, v4.y, v4.z)
    }
    
    @inlinable func multiplyPoint(_ point: SCNVector4) -> SCNVector4 {
        SCNVector4(
            self.m11 * point.x + self.m21 * point.y + self.m31 * point.z + self.m41 * point.w,
            self.m12 * point.x + self.m22 * point.y + self.m32 * point.z + self.m42 * point.w,
            self.m13 * point.x + self.m23 * point.y + self.m33 * point.z + self.m43 * point.w,
            self.m14 * point.x + self.m24 * point.y + self.m34 * point.z + self.m44 * point.w
        )
    }
}
