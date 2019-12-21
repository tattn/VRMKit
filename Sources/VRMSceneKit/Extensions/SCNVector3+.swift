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
    func createSCNVector3() -> SCNVector3 {
        return .init(x: SCNFloat(x), y: SCNFloat(y), z: SCNFloat(z))
    }
}
