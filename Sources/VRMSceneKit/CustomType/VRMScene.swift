//
//  VRMScene.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import SceneKit
import VRMKit

open class VRMScene: SCNScene {
    public let vrm: VRM
    let sceneData: SceneData

    init(vrm: VRM, sceneData: SceneData) {
        self.vrm = vrm
        self.sceneData = sceneData
        super.init()
    }

    @available(*, unavailable)
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
