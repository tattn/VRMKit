//
//  ViewModel.swift
//  WatchExample Watch App
//
//  Created by Tatsuya Tanaka on 2023/09/10.
//  Copyright © 2023 tattn. All rights reserved.
//

import Foundation
import VRMSceneKit
import SceneKit

final class Renderer: NSObject, SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        (renderer.scene as! VRMScene).vrmNode.update(at: time)
    }
}

final class ViewModel: ObservableObject {
    @Published private(set) var scene: VRMScene?
    let renderer = Renderer()

    func loadModelIfNeeded() {
        guard scene == nil else { return }

        do {
            let loader = try VRMSceneLoader(named: "AliciaSolid.vrm")
            let scene = try loader.loadScene()
            setupScene(scene)

            let node = scene.vrmNode
            node.humanoid.node(for: .leftShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
            node.humanoid.node(for: .rightShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / -180)

            node.runAction(.repeatForever(.sequence([
                .wait(duration: 3.0),
                .customAction(duration: 0.5) { node, time in
                    let vrmNode = node as! VRMNode
                    return vrmNode.setBlendShape(value: time / 0.5, for: .preset(.blink))
                },
                .customAction(duration: 0.5) { node, time in
                    let vrmNode = node as! VRMNode
                    return vrmNode.setBlendShape(value: 1.0 - time / 0.5, for: .preset(.blink))
                },
            ])))
        } catch {
            print(error)
        }
    }

    private func setupScene(_ scene: VRMScene) {
        self.scene = scene

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        scene.rootNode.addChildNode(cameraNode)

        cameraNode.position = SCNVector3(0, 1.4, -0.4)
        cameraNode.rotation = SCNVector4(0, 1, 0, Float.pi)
    }
}
