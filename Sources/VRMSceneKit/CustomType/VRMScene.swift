//
//  VRMScene.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 2019/02/11.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit

open class VRMScene: SCNScene {
    public let vrmNode: VRMNode

    init(node: VRMNode) {
        self.vrmNode = node
        super.init()
        rootNode.addChildNode(vrmNode)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
