//
//  VRMNodeComponent.swift
//  VRMKit
//
//  Created by Tomoya Hirano on 2019/12/22.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit
import GameKit

@available(iOS 11.0, *)
public class VRMNodeComponent: GKSCNNodeComponent {
    private var springBones: [VRMSpringBone] = []
    
    func setUpSpringBones(loader: VRMSceneLoader) throws {
        guard let vrmNode = node as? VRMNode else { preconditionFailure() }
        var springBones: [VRMSpringBone] = []
        let secondaryAnimation = vrmNode.vrm.secondaryAnimation
        for boneGroup in secondaryAnimation.boneGroups {
            guard !boneGroup.bones.isEmpty else { return }
            let rootBones: [SCNNode] = try boneGroup.bones.compactMap({ try loader.node(withNodeIndex: $0) }).compactMap({ $0 })
            let centerIndex = max(boneGroup.center, boneGroup.bones[0])
            if let centerNode = try? loader.node(withNodeIndex: centerIndex) {
                let colliderGroups = try secondaryAnimation.colliderGroups.map({ try VRMSpringBoneColliderGroup(colliderGroup: $0, loader: loader) })
                let springBone = VRMSpringBone(center: centerNode,
                                               rootBones: rootBones,
                                               comment: boneGroup.comment,
                                               stiffnessForce: SCNFloat(boneGroup.stiffiness),
                                               gravityPower: SCNFloat(boneGroup.gravityPower),
                                               gravityDir: boneGroup.gravityDir.createSCNVector3(),
                                               dragForce: SCNFloat(boneGroup.dragForce),
                                               hitRadius: SCNFloat(boneGroup.hitRadius),
                                               colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        }
        self.springBones = springBones
    }
    
    override public func update(deltaTime seconds: TimeInterval) {
        super.update(deltaTime: seconds)
        springBones.forEach({ $0.update(deltaTime: seconds) })
    }
}
