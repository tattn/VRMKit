//
//  VRMSpringBone.swift
//  SpringBoneKit
//
//  Created by Tomoya Hirano on 2019/12/20.
//  Copyright © 2019 Tomoya Hirano. All rights reserved.
//

import SceneKit
import GameKit
import VRMKit

@available(iOS 11.0, *)
final class VRMSpringBone {
    struct SphereCollider {
        let position: SCNVector3
        let radius: SCNFloat
    }
    
    public let comment: String?
    public let stiffnessForce: SCNFloat
    public let gravityPower: SCNFloat
    public let gravityDir: SCNVector3
    public let dragForce: SCNFloat
    public let center: SCNNode
    public let rootBones: [SCNNode]
    public let hitRadius: SCNFloat
    
    private var initialLocalRotationMap: [SCNNode : SCNQuaternion] = [:]
    private let colliderGroups: [VRMSpringBoneColliderGroup]
    private var verlet: [SpringBoneLogic] = []
    private var colliderList: [SphereCollider] = []
    
    init(center: SCNNode,
         rootBones: [SCNNode],
         comment: String? = nil,
         stiffnessForce: SCNFloat = 1.0,
         gravityPower: SCNFloat = 0.0,
         gravityDir: SCNVector3 = .init(0, -1, 0),
         dragForce: SCNFloat = 0.4,
         hitRadius: SCNFloat = 0.02,
         colliderGroups: [VRMSpringBoneColliderGroup] = []) {
        self.center = center
        self.rootBones = rootBones
        self.comment = comment
        self.stiffnessForce = stiffnessForce
        self.gravityPower = gravityPower
        self.gravityDir = gravityDir
        self.dragForce = dragForce
        self.hitRadius = hitRadius
        self.colliderGroups = colliderGroups
        setup()
    }
    
    private func setup() {
        guard !rootBones.isEmpty else { return }
        
        for kv in initialLocalRotationMap {
            kv.key.orientation = kv.value
        }
        
        verlet = []
        
        initialLocalRotationMap = [:]
        for boneNode in rootBones {
            for childNode in boneNode.childNodes {
                initialLocalRotationMap[childNode] = childNode.orientation
            }
            setupRecursive(center: center, parent: boneNode)
        }
    }
    
    private func setupRecursive(center: SCNNode, parent: SCNNode) {
        if let firstChildNode = parent.childNodes.first {
            let localPosition = firstChildNode.position
            let scale = firstChildNode.scale
            let logic = SpringBoneLogic(center: center, node: parent, localChildPosition: SCNVector3(localPosition.x * scale.x, localPosition.y * scale.y, localPosition.z * scale.z))
            verlet.append(logic)
        } else {
            let delta: SCNVector3 = parent.worldPosition - (parent.parent?.worldPosition ?? SCNVector3())
            let childPosition = parent.worldPosition + delta.normalized * 0.07
            let logic = SpringBoneLogic(center: center, node: parent, localChildPosition: parent.worldToLocalMatrix * childPosition)
            verlet.append(logic)
        }
        
        parent.childNodes.forEach { (child) in
            setupRecursive(center: center, parent: child)
        }
    }
    
    private func setLocalRotationsIdentity() {
        for verlet in verlet {
            verlet.node.orientation = SCNQuaternion.identity
        }
    }
    
    func update(deltaTime seconds: TimeInterval) {
        if verlet.isEmpty {
            if rootBones.isEmpty {
                return
            }
            setup()
        }
        colliderList = []
        for colliderGroup in colliderGroups {
            for collider in colliderGroup.colliders {
                colliderList.append(SphereCollider(
                    position: colliderGroup.node.convertPosition(collider.offset, to: colliderGroup.node),
                    radius: SCNFloat(collider.radius)
                ))
            }
        }
        let stiffness = stiffnessForce * SCNFloat(seconds)
        let external = gravityDir * (gravityPower * SCNFloat(seconds))
        for verlet in verlet {
            verlet.radius = hitRadius
            verlet.update(center: center,
                          stiffnessForce: stiffness,
                          dragForce: dragForce,
                          external: external,
                          colliders: colliderList)
        }
    }
}

@available(iOS 11.0, *)
extension VRMSpringBone {
    class SpringBoneLogic {
        let node: SCNNode
        private let length: SCNFloat
        private var currentTail: SCNVector3
        private var prevTail: SCNVector3
        private let localRotation: SCNQuaternion
        private let boneAxis: SCNVector3
        private var parentRotation: SCNQuaternion {
            node.parent?.worldOrientation ?? SCNQuaternion.identity
        }
        var radius: SCNFloat = 0.5
        
        init(center: SCNNode, node: SCNNode, localChildPosition: SCNVector3) {
            self.node = node
            let worldChildPosition = node.convertPosition(localChildPosition, to: node)
            currentTail = center.convertPosition(worldChildPosition, from: center)
            prevTail = currentTail
            localRotation = node.orientation
            boneAxis = localChildPosition.normalized
            length = localChildPosition.length
        }
        
        func update(center: SCNNode, stiffnessForce: SCNFloat, dragForce: SCNFloat, external: SCNVector3, colliders: [SphereCollider]) {
            let currentTail: SCNVector3 = center.convertPosition(self.currentTail, to: center)
            let prevTail: SCNVector3 = center.convertPosition(self.prevTail, to: center)
            // verlet積分で次の位置を計算
            var nextTail: SCNVector3 = currentTail
                + (currentTail - prevTail) * (1.0 - dragForce) // 前フレームの移動を継続する(減衰もあるよ)
                + parentRotation * localRotation * boneAxis * stiffnessForce // 親の回転による子ボーンの移動目標
                + external // 外力による移動量
            
            // 長さをboneLengthに強制
            nextTail = self.node.worldPosition + (nextTail - node.worldPosition).normalized * length
            
            // Collisionで移動
            nextTail = collision(colliders, nextTail: nextTail)
            
            self.prevTail = center.convertPosition(currentTail, from: center)
            self.currentTail = center.convertPosition(nextTail, from: center)
            
            // 回転を適用
            self.node.worldOrientation = applyRotation(nextTail)
        }
        
        private func applyRotation(_ nextTail: SCNVector3) -> SCNQuaternion {
            let rotation = parentRotation * localRotation
            return SCNQuaternion(from: rotation * boneAxis, to: nextTail - node.worldPosition) * rotation
        }
        
        private func collision(_ colliders: [SphereCollider], nextTail: SCNVector3) -> SCNVector3 {
            var nextTail = nextTail
            for collider in colliders {
                let r = radius + collider.radius
                if (nextTail - collider.position).magnitudeSquared <= (r * r) {
                    // ヒット。Colliderの半径方向に押し出す
                    let normal = (nextTail - collider.position).normalized
                    let posFromCollider = collider.position + normal * (radius + collider.radius)
                    // 長さをboneLengthに強制
                    nextTail = node.worldPosition + (posFromCollider - node.worldPosition).normalized * length
                }
            }
            return nextTail
        }
    }
}
