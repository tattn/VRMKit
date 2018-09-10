//
//  GLTF2SCN.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import Foundation
import SceneKit
import SpriteKit

func semantic(of key: GLTF.Mesh.Primitive.AttributeKey) -> SCNGeometrySource.Semantic {
    switch key {
    case .POSITION: return .vertex
    case .NORMAL: return .normal
    case .TANGENT: return .tangent
    case .TEXCOORD_0: return .texcoord
    case .TEXCOORD_1: return .texcoord
    case .COLOR_0: return .color
    case .JOINTS_0: return .boneIndices
    case .WEIGHTS_0: return .boneWeights
    }
}

func numberOfComponents(of type: GLTF.Accessor.`Type`) -> Int {
    switch type {
    case .SCALAR: return 1
    case .VEC2: return 2
    case .VEC3: return 3
    case .VEC4: return 4
    case .MAT2: return 4
    case .MAT3: return 9
    case .MAT4: return 16
    }
}

func bytes(of type: GLTF.Accessor.ComponentType) -> Int {
    switch type {
    case .byte, .unsignedByte: return 1
    case .short, .unsignedShort: return 2
    case .unsignedInt, .float: return 4
    }
}

extension SCNGeometryPrimitiveType {
    func primitiveCount(ofCount count: Int) -> Int {
        switch self {
        case .line: return count / 2
        case .point: return count
        case .polygon: return count - 2
        case .triangles: return count / 3
        case .triangleStrip: return count - 2
        }
    }
}

func primitiveTypeOf(_ mode: GLTF.Mesh.Primitive.Mode) -> SCNGeometryPrimitiveType? {
    switch mode {
    case .POINTS: return .point
    case .LINES: return .line
    case .TRIANGLES: return .triangles
    case .TRIANGLE_STRIP: return .triangleStrip
    case .LINE_LOOP, .LINE_STRIP, .TRIANGLE_FAN: return nil // TODO
    }
}

extension GLTF.Matrix {
    func createSCNMatrix4() -> SCNMatrix4 {
        let v = values
        return SCNMatrix4(
            m11: v[0], m12: v[1], m13: v[2], m14: v[3],
            m21: v[4], m22: v[5], m23: v[6], m24: v[7],
            m31: v[8], m32: v[9], m33: v[10], m34: v[11],
            m41: v[12], m42: v[13], m43: v[14], m44: v[15])
    }
}

extension GLTF.Vector3 {
    func createSCNVector3() -> SCNVector3 {
        return .init(x: SCNFloat(x), y: SCNFloat(y), z: SCNFloat(z))
    }
}

extension GLTF.Vector4 {
    func createSCNVector4() -> SCNVector4 {
        return .init(x: SCNFloat(x), y: SCNFloat(y), z: SCNFloat(z), w: SCNFloat(w))
    }
}

extension GLTF.Color4 {
    func createSKColor() -> SKColor {
        return .init(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}
