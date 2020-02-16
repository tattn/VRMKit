//
//  SCNVector3+.swift
//  VRMKit
//
//  Created by Tomoya Hirano on 2019/12/21.
//  Copyright © 2019 tattn. All rights reserved.
//

import VRMKit
import SceneKit

extension VRM.Vector3 {
    var simd: SIMD3<Float> {
        SIMD3<Float>(x: Float(x), y: Float(y), z: Float(z))
    }
}
