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
        SCNVector3(left.x + right.x, left.y + right.y, left.z + right.z)
    }

    static func - (_ left: SCNVector3, _ right: SCNVector3) -> SCNVector3 {
        SCNVector3(left.x - right.x, left.y - right.y, left.z - right.z)
    }

    static func * (_ left: SCNVector3, _ value: SCNFloat) -> SCNVector3 {
        SCNVector3(left.x * value, left.y * value, left.z * value)
    }

    static func / (_ left: SCNVector3, _ value: SCNFloat) -> SCNVector3 {
        left * (1.0 / value)
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

    var sqrMagnitude: SCNFloat {
        x * x + y * y + z * z
    }

    var magnitude: SCNFloat {
        sqrt(sqrMagnitude)
    }

    var normalized: SCNVector3 {
        self * (1.0 / magnitude)
    }
    
    mutating func normalize() {
        self = normalized
    }
}

func cross(_ left: SCNVector3, _ right: SCNVector3) -> SCNVector3 {
    SCNVector3(left.y * right.z - left.z * right.y, left.z * right.x - left.x * right.z, left.x * right.y - left.y * right.x)
}

func normal(_ v0: SCNVector3, _ v1: SCNVector3, _ v2: SCNVector3) -> SCNVector3 {
    let e1 = v1 - v0
    let e2 = v2 - v0
    let n = cross(e1, e2)

    return n.normalized
}

func dot(_ left: SCNVector3, _ right: SCNVector3) -> SCNFloat {
    left.x * right.x + left.y * right.y + left.z * right.z
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

extension SCNMatrix4 {
    init(_ v: [SCNFloat]) throws {
        guard v.count == 16 else { throw "SCNMatrix4: values.count must be 16" }
        self.init(m11: v[0], m12: v[1], m13: v[2], m14: v[3],
                  m21: v[4], m22: v[5], m23: v[6], m24: v[7],
                  m31: v[8], m32: v[9], m33: v[10], m34: v[11],
                  m41: v[12], m42: v[13], m43: v[14], m44: v[15])
    }
    
    static func * (_ left: SCNMatrix4, right: SCNMatrix4) -> SCNMatrix4 {
        SCNMatrix4Mult(left, right)
    }
}

extension String: Error {}
