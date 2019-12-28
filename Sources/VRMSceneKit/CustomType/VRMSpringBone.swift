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
    private var verlet: [VRMSpringBoneLogic] = []
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
        for kv in self.initialLocalRotationMap {
            kv.key.utx.localRotation = kv.value
        }
        self.initialLocalRotationMap = [:]
        self.verlet = []

        for go in self.rootBones {
            go.enumerateHierarchy { (x, _) in
                self.initialLocalRotationMap[x] = x.utx.localRotation
            }
            setupRecursive(self.center, go)
        }
    }
    
    private func setupRecursive(_ center: SCNNode, _ parent: SCNNode) {
        if parent.utx.childCount == 0 {
            let delta = parent.utx.position - parent.parent!.utx.position
            let childPosition = parent.utx.position + delta.normalized * 0.07
            let logic = VRMSpringBoneLogic(center: center, node: parent, localChildPosition: parent.utx.worldToLocalMatrix.multiplyPoint(childPosition))
            self.verlet.append(logic)
        } else {
            let firstChild = parent.childNodes.first!
            let localPosition = firstChild.utx.localPosition
            let scale = firstChild.utx.lossyScale
            let logic = VRMSpringBoneLogic(center: center, node: parent, localChildPosition: SCNVector3(
                localPosition.x * scale.x,
                localPosition.y * scale.y,
                localPosition.z * scale.z
            ))
            self.verlet.append(logic)
        }

        for child in parent {
            self.setupRecursive(center, child)
        }
    }
    
    private func setLocalRotationsIdentity() {
        for verlet in self.verlet {
            verlet.head.utx.localRotation = SCNQuaternion.identity
        }
    }
    
    func update(deltaTime: TimeInterval) {
        if self.verlet.isEmpty {
            if self.rootBones.isEmpty {
                return
            }
            setup()
        }

        self.colliderList = []
        for group in self.colliderGroups {
            for collider in group.colliders {
                self.colliderList.append(SphereCollider(
                    position: group.node.utx.transformPoint(collider.offset),
                    radius: collider.radius
                ))
            }
        }

        let stiffness = self.stiffnessForce * SCNFloat(deltaTime)
        let external = self.gravityDir * (self.gravityPower * SCNFloat(deltaTime))

        for verlet in self.verlet {
            verlet.radius = self.hitRadius
            verlet.update(
                center: self.center,
                stiffnessForce: stiffness,
                dragForce: self.dragForce,
                external: external,
                colliders: self.colliderList)
        }
    }
}

extension VRMSpringBone {
    class VRMSpringBoneLogic {
        let node: SCNNode
        public var head: SCNNode { self.node }
        private let length: SCNFloat
        private var currentTail: SCNVector3
        private var prevTail: SCNVector3
        private let localRotation: SCNQuaternion
        private let boneAxis: SCNVector3
        private var parentRotation: SCNQuaternion {
            self.node.parent?.utx.rotation ?? SCNQuaternion.identity
        }
        var radius: SCNFloat = 0.5
        
        init(center: SCNNode, node: SCNNode, localChildPosition: SCNVector3) {
            self.node = node
            let worldChildPosition = node.utx.transformPoint(localChildPosition)
            self.currentTail = center.utx.inverseTransformPoint(worldChildPosition)
            self.prevTail = self.currentTail
            self.localRotation = node.utx.localRotation
            self.boneAxis = localChildPosition.normalized
            self.length = localChildPosition.magnitude
        }
        
        func update(center: SCNNode, stiffnessForce: SCNFloat, dragForce: SCNFloat, external: SCNVector3, colliders: [SphereCollider]) {
            let currentTail: SCNVector3 = center.utx.transformPoint(self.currentTail)
            let prevTail: SCNVector3 = center.utx.transformPoint(self.prevTail)

            // verlet積分で次の位置を計算
            var nextTail: SCNVector3 = {
                let a = currentTail
                let b = (currentTail - prevTail) * (1.0 - dragForce) // 前フレームの移動を継続する(減衰もあるよ)
                let c = self.parentRotation * self.localRotation * self.boneAxis * stiffnessForce // 親の回転による子ボーンの移動目標
                let d = external // 外力による移動量
                return a + b + c + d
            }()
            
            // 長さをboneLengthに強制
            nextTail = self.node.utx.position + (nextTail - self.node.utx.position).normalized * self.length

            // Collisionで移動
            nextTail = self.collision(colliders, nextTail)

            self.prevTail = center.utx.inverseTransformPoint(currentTail)
            self.currentTail = center.utx.inverseTransformPoint(nextTail)

            //回転を適用
            self.head.utx.rotation = self.applyRotation(nextTail)
        }
        
        private func applyRotation(_ nextTail: SCNVector3) -> SCNQuaternion {
            let rotation = self.parentRotation * self.localRotation
            return SCNQuaternion(from: rotation * self.boneAxis, to: nextTail - self.node.utx.position) * rotation
        }
        
        private func collision(_ colliders: [SphereCollider], _ nextTail: SCNVector3) -> SCNVector3 {
            var nextTail = nextTail
            for collider in colliders {
                let r = self.radius + collider.radius
                if SCNVector3.sqrMagnitude(nextTail - collider.position) <= (r * r) {
                    // ヒット。Colliderの半径方向に押し出す
                    let normal = (nextTail - collider.position).normalized
                    let posFromCollider = collider.position + normal * (self.radius + collider.radius)
                    // 長さをboneLengthに強制
                    nextTail = self.node.utx.position + (posFromCollider - self.node.utx.position).normalized * self.length
                }
            }
            return nextTail
        }
    }
}
