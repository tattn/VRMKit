//
//  SCNMorpher+GLTF.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 2019/02/09.
//  Copyright © 2019 tattn. All rights reserved.
//

import VRMKit
import SceneKit

extension SCNMorpher {
    convenience init(primitiveTargets: [[GLTF.Mesh.Primitive.AttributeKey: Int]], loader: VRMSceneLoader) throws {
        self.init()
        for target in primitiveTargets {
            let sources = try loader.attributes(target)
            let geometry = SCNGeometry(sources: sources, elements: nil)
            targets.append(geometry)
        }
        calculationMode = .additive
    }
}
