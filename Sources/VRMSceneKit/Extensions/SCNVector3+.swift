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
    var simd: simd_float3 {
        simd_float3(x: Float(x), y: Float(y), z: Float(z))
    }
}
