//
//  SceneKit+.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import SceneKit
import SpriteKit

extension SCNVector3 {
    static func + (_ left: SCNVector3, _ right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x + right.x, left.y + right.y, left.z + right.z)
    }

    static func - (_ left: SCNVector3, _ right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x - right.x, left.y - right.y, left.z - right.z)
    }

    static func * (_ left: SCNVector3, _ value: SCNFloat) -> SCNVector3 {
        return SCNVector3(left.x * value, left.y * value, left.z * value)
    }

    static func / (_ left: SCNVector3, _ value: SCNFloat) -> SCNVector3 {
        return left * (1.0 / value)
    }

    static func += (_ left: inout SCNVector3, _ right: SCNVector3) {
        left = left + right
    }

    static func -= (_ left: inout SCNVector3, _ right: SCNVector3) {
        left = left - right
    }

    static func *= (_ left: inout SCNVector3, _ right: SCNFloat) {
        left = left * right
    }

    static func /= (_ left: inout SCNVector3, _ right: SCNFloat) {
        left = left / right
    }

    var length: SCNFloat {
        return SCNFloat(sqrtf(x * x + y * y + z * z))
    }

    var normalized: SCNVector3 {
        return self * (1.0 / length)
    }

    mutating func normalize() {
        self = normalized
    }
}

func cross(_ left: SCNVector3, _ right: SCNVector3) -> SCNVector3 {
    return SCNVector3(left.y * right.z - left.z * right.y, left.z * right.x - left.x * right.z, left.x * right.y - left.y * right.x)
}

func normal(_ v0: SCNVector3, _ v1: SCNVector3, _ v2: SCNVector3) -> SCNVector3 {
    let e1 = v1 - v0
    let e2 = v2 - v0
    let n = cross(e1, e2)

    return n.normalized
}

extension SCNMaterial {
    static var `default`: SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = SKColor(red: 1, green: 1, blue: 1, alpha: 1)
        material.metalness.contents = SKColor(white: 1, alpha: 1)
        material.roughness.contents = SKColor(white: 1, alpha: 1)
        material.isDoubleSided = false
        material.lightingModel = .physicallyBased
        return material
    }
}
