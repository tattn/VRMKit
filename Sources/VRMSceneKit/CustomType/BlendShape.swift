//
//  BlendShape.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 2019/02/10.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit

struct BlendShapeClip {
    let name: String
    let preset: BlendShapePreset
    let values: [BlendShapeBinding]
    //        let materialValues: [MaterialValueBinding] // TODO:
    let isBinary: Bool
    var key: BlendShapeKey {
        return preset == .unknown ? .custom(name) : .preset(preset)
    }
}

struct BlendShapeBinding {
    let mesh: SCNNode
    let index: Int
    let weight: Double
}

struct MaterialValueBinding {
    let materialName: String
    let valueName: String
    let targetValue: SCNVector4
    let baseValue: SCNVector4
}

public enum BlendShapeKey: Hashable {
    case preset(BlendShapePreset)
    case custom(String)
    var isPreset: Bool {
        switch self {
        case .preset: return true
        case .custom: return false
        }
    }
}

public enum BlendShapePreset: String {
    case unknown
    case neutral
    case a
    case i
    case u
    case e
    case o
    case blink
    case joy
    case angry
    case sorrow
    case fun
    case lookUp = "lookup"
    case lookDown = "lookdown"
    case lookLeft = "lookleft"
    case lookRight = "lookright"
    case blinkL = "blink_l"
    case blinkR = "blink_r"

    init(name: String) {
        self = BlendShapePreset(rawValue: name.lowercased()) ?? .unknown
    }
}
