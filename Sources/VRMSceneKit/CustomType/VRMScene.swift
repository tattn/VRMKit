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
    open let vrm: VRM

    public init(vrm: VRM) {
        self.vrm = vrm
        super.init()
    }

    @available(*, unavailable)
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
