//
//  ContentView.swift
//  WatchExample Watch App
//
//  Created by Naoto Komiya on 2023/09/08.
//  Copyright © 2023 tattn. All rights reserved.
//

import SwiftUI
import SceneKit
import VRMKit
import VRMSceneKit

class Renderer : NSObject, SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        (renderer.scene as! VRMScene).vrmNode.update(at: time)
    }
}

struct ContentView: View {
    var scene: VRMScene?
    var renderer: Renderer = Renderer()

    private func setupScene(_ scene: SCNScene) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        scene.rootNode.addChildNode(cameraNode)

        cameraNode.position = SCNVector3(0, 1.4, -0.4)
        cameraNode.rotation = SCNVector4(0, 1, 0, Float.pi)
    }

    init() {
        do {
            let loader = try VRMSceneLoader(named: "AliciaSolid.vrm")
            scene = try loader.loadScene()
            if(scene != nil) {
                setupScene(scene!)
                let node = scene!.vrmNode
                node.humanoid.node(for: .leftShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
                node.humanoid.node(for: .rightShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / -180)

                node.runAction(SCNAction.repeatForever(SCNAction.sequence([
                    SCNAction.wait(duration: 3.0),
                    SCNAction.customAction(duration: 0.5, action: {(node, time)->Void in
                        let vrmNode = node as! VRMNode
                        return vrmNode.setBlendShape(value: time/0.5, for: .preset(.blink))
                    }),
                    SCNAction.customAction(duration: 0.5, action: {(node, time)->Void in
                        let vrmNode = node as! VRMNode
                        return vrmNode.setBlendShape(value: 1.0-time/0.5, for: .preset(.blink))
                    }),
                ])))
            }
        } catch {
            print(error)
        }
    }

    var body: some View {
        VStack {
            SceneView(scene: scene, delegate: renderer).padding(.vertical,-45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
