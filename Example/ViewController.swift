//
//  ViewController.swift
//  VRMExample
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import UIKit
import SceneKit
import VRMKit
import VRMSceneKit
import GameKit

class ViewController: UIViewController {

    @IBOutlet private weak var scnView: SCNView! {
        didSet {
            scnView.autoenablesDefaultLighting = true
            scnView.allowsCameraControl = true
            scnView.showsStatistics = true
            scnView.backgroundColor = UIColor.black
        }
    }
    
    let gkScene: GKScene = .init()
    var lastUpdateTime = TimeInterval()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        do {
            let loader = try VRMSceneLoader(named: "AliciaSolid.vrm")
            let scene = try loader.loadScene()
            setupScene(scene)
            scnView.scene = scene
            scnView.delegate = self
            let node = scene.vrmNode
            node.setBlendShape(value: 1.0, for: .custom("><"))
            node.humanoid.node(for: .neck)?.eulerAngles = SCNVector3(0, 0, 20 * CGFloat.pi / 180)
            node.humanoid.node(for: .leftShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
            node.humanoid.node(for: .rightShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
            let component = try loader.loadComponent(vrmNode: node)
            let entity = GKEntity()
            entity.addComponent(component)
            gkScene.addEntity(entity)
            
            node.runAction(SCNAction.repeatForever(SCNAction.sequence([
                SCNAction.rotateBy(x: 0, y: -0.5, z: 0, duration: 0.5),
                SCNAction.rotateBy(x: 0, y: 0.5, z: 0, duration: 0.5),
            ])))
        } catch {
            print(error)
        }
    }

    private func setupScene(_ scene: SCNScene) {
//        let enviromentLightNode = SCNNode()
//        let enviromentLight = SCNLight()
//        enviromentLightNode.light = enviromentLight
//        enviromentLight.type = .ambient
//        enviromentLight.color = UIColor.white
//        scene.rootNode.addChildNode(enviromentLightNode)
//
//        let pointLightNode = SCNNode()
//        let pointLight = SCNLight()
//        pointLightNode.light = pointLight
//        pointLight.type = .spot
//        pointLight.color = UIColor.white
//        enviromentLight.intensity = 1000
//        enviromentLightNode.position = SCNVector3(x: 0, y: 0, z: -2)
//        scene.rootNode.addChildNode(pointLightNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)

        cameraNode.position = SCNVector3(0, 0.8, -1.6)
        cameraNode.rotation = SCNVector4(0, 1, 0, Float.pi)
    }
}

extension ViewController: SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if lastUpdateTime == 0 {
            lastUpdateTime = time
        }
        let deltaTime: TimeInterval = time - lastUpdateTime
        lastUpdateTime = time
        gkScene.entities.forEach({ $0.update(deltaTime: deltaTime) })
    }
}
