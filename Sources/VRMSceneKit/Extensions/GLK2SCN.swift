//
//  GLK2SCN.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2019/12/21.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit
import simd

extension SCNVector3 {
    var toSimd: SIMD3<Float> {
        SIMD3<Float>(self)
    }
    
    var toGLK: GLKVector3 {
        SCNVector3ToGLKVector3(self)
    }
}

extension GLKVector3 {
    var toSCN: SCNVector3 {
        SCNVector3FromGLKVector3(self)
    }
}

extension SCNQuaternion {
    var q: (Float,Float,Float,Float) {
        (Float(self.x), Float(self.y), Float(self.z), Float(self.w))
    }
    
    init(q: (Float,Float,Float,Float)) {
        self.init(x: SCNFloat(q.0), y: SCNFloat(q.1), z: SCNFloat(q.2), w: SCNFloat(q.3))
    }
    
    var toGLK: GLKQuaternion {
        GLKQuaternion(q: self.q)
    }
}

extension GLKQuaternion {
    var toSCN: SCNQuaternion {
        SCNQuaternion(q: self.q)
    }
}
