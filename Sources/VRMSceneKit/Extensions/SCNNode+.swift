//
//  SCNNode+.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2019/12/21.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit

extension SCNNode {
    var localToWorldMatrix: SCNMatrix4 {
        convertTransform(transform, to: parent) * convertTransform(transform, to: self)
    }
    
    var worldToLocalMatrix: SCNMatrix4 {
        localToWorldMatrix.inverted
    }
}
