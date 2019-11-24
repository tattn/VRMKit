//
//  SCNSkinner+GLTF.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 2019/02/11.
//  Copyright © 2019 tattn. All rights reserved.
//

import VRMKit
import SceneKit

extension SCNSkinner {
    convenience init(primitiveGeometry: SCNGeometry,
                     bones: [SCNNode],
                     boneInverseBindTransform ibm: [InverseBindMatrix]?) throws {
        let weightsSources = primitiveGeometry.sources(for: .boneWeights)
        guard let weights = weightsSources[safe: 0] else { throw VRMError.dataInconsistent("boneWeights is not found") }
        let indicesSources = primitiveGeometry.sources(for: .boneIndices)
        guard let indices = indicesSources[safe: 0] else { throw VRMError.dataInconsistent("boneIndices is not found") }
        self.init(baseGeometry: primitiveGeometry,
                  bones: bones,
                  boneInverseBindTransforms: ibm,
                  boneWeights: weights,
                  boneIndices: indices)
    }
}
