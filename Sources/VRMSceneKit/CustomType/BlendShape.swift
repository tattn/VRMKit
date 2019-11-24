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
    case lookUp
    case lookDown
    case lookLeft
    case lookRight
    case blinkL
    case blinkR

    init(name: String) {
        self = BlendShapePreset(rawValue: name.lowerCamelized()) ?? .unknown
    }
}

private extension String {
    func lowerCamelized() -> String {
        let words = lowercased().split(separator: "_").map(String.init)
        return words.dropFirst().reduce(into: words.first ?? "", { result, word in
            result.append(String(word.prefix(1).capitalized) + String(word.suffix(from: index(after: startIndex))))
        })
    }
}
