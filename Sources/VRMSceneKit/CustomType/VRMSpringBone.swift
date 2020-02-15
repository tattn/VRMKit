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
        let position: simd_float3
        let radius: simd_float1
    }
    
    public let comment: String?
    public let stiffnessForce: simd_float1
    public let gravityPower: simd_float1
    public let gravityDir: simd_float3
    public let dragForce: simd_float1
    public let center: SCNNode?
    public let rootBones: [SCNNode]
    public let hitRadius: simd_float1
    
    private var initialLocalRotationMap: [SCNNode : simd_quatf] = [:]
    private let colliderGroups: [VRMSpringBoneColliderGroup]
    private var verlet: [VRMSpringBoneLogic] = []
    private var colliderList: [SphereCollider] = []
    
    private let isDrawGizmo: Bool
    
    init(center: SCNNode?,
         rootBones: [SCNNode],
         comment: String? = nil,
         stiffnessForce: simd_float1 = 1.0,
         gravityPower: simd_float1 = 0.0,
         gravityDir: simd_float3 = .init(0, -1, 0),
         dragForce: simd_float1 = 0.4,
         hitRadius: simd_float1 = 0.02,
         colliderGroups: [VRMSpringBoneColliderGroup] = [],
         isDrawGizmo: Bool = false) {
        self.center = center
        self.rootBones = rootBones
        self.comment = comment
        self.stiffnessForce = stiffnessForce
        self.gravityPower = gravityPower
        self.gravityDir = gravityDir
        self.dragForce = dragForce
        self.hitRadius = hitRadius
        self.colliderGroups = colliderGroups
        self.isDrawGizmo = isDrawGizmo
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
    
    private func setupRecursive(_ center: SCNNode?, _ parent: SCNNode) {
        if parent.utx.childCount == 0 {
            let delta = parent.utx.position - parent.parent!.utx.position
            let childPosition = parent.utx.position + delta.normalized * 0.07
            let logic = VRMSpringBoneLogic(center: center, node: parent, localChildPosition: parent.utx.worldToLocalMatrix.multiplyPoint(childPosition))
            self.verlet.append(logic)
        } else {
            let firstChild = parent.childNodes.first!
            let localPosition = firstChild.utx.localPosition
            let scale = firstChild.utx.lossyScale
            let logic = VRMSpringBoneLogic(center: center, node: parent, localChildPosition: simd_float3(
                localPosition.x * scale.x,
                localPosition.y * scale.y,
                localPosition.z * scale.z
            ))
            self.verlet.append(logic)
        }

        for child in parent.childNodes {
            self.setupRecursive(center, child)
        }
    }
    
    private func setLocalRotationsIdentity() {
        for verlet in self.verlet {
            verlet.head.utx.localRotation = quart_identity_float
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

        let stiffness = self.stiffnessForce * simd_float1(deltaTime)
        let external = self.gravityDir * (self.gravityPower * simd_float1(deltaTime))

        for verlet in self.verlet {
            verlet.radius = self.hitRadius
            verlet.update(
                center: self.center,
                stiffnessForce: stiffness,
                dragForce: self.dragForce,
                external: external,
                colliders: self.colliderList)
        }
        onDrawGizmos()
    }
    
    func onDrawGizmos() {
        if isDrawGizmo {
            let gizmoNodeName = "VRMKit.gizmoNode"
            guard let baseNode = rootBones.first else { return }
            baseNode.childNodes.filter({ $0.name == gizmoNodeName }).forEach({ $0.removeFromParentNode() })
            for verlet in self.verlet {
                verlet.drawGizmo(
                    base: baseNode,
                    center: self.center,
                    radius: self.hitRadius,
                    color: UIColor.yellow,
                    gizmoNodeName: gizmoNodeName
                )
            }
        }
    }
}

extension VRMSpringBone {
    class VRMSpringBoneLogic {
        let node: SCNNode
        public var head: SCNNode { self.node }
        private let length: simd_float1
        private var currentTail: simd_float3
        private var prevTail: simd_float3
        private let localRotation: simd_quatf
        private let boneAxis: simd_float3
        private var parentRotation: simd_quatf {
            self.node.parent?.utx.rotation ?? quart_identity_float
        }
        var radius: simd_float1 = 0.5
        
        init(center: SCNNode?, node: SCNNode, localChildPosition: simd_float3) {
            self.node = node
            let worldChildPosition = node.utx.transformPoint(localChildPosition)
            self.currentTail = center?.utx.inverseTransformPoint(worldChildPosition) ?? worldChildPosition
            self.prevTail = self.currentTail
            self.localRotation = node.utx.localRotation
            self.boneAxis = localChildPosition.normalized
            self.length = localChildPosition.length
        }
        
        func update(center: SCNNode?, stiffnessForce: simd_float1, dragForce: simd_float1, external: simd_float3, colliders: [SphereCollider]) {
            let currentTail: simd_float3 = center?.utx.transformPoint(self.currentTail) ?? self.currentTail
            let prevTail: simd_float3 = center?.utx.transformPoint(self.prevTail) ?? self.prevTail

            // verlet積分で次の位置を計算
            var nextTail: simd_float3 = {
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

            self.prevTail = center?.utx.inverseTransformPoint(currentTail) ?? currentTail
            self.currentTail = center?.utx.inverseTransformPoint(nextTail) ?? nextTail

            //回転を適用
            self.head.utx.rotation = self.applyRotation(nextTail)
        }
        
        private func applyRotation(_ nextTail: simd_float3) -> simd_quatf {
            let rotation = self.parentRotation * self.localRotation
            return simd_quatf(from: rotation * self.boneAxis, to: nextTail - self.node.utx.position) * rotation
        }
        
        private func collision(_ colliders: [SphereCollider], _ nextTail: simd_float3) -> simd_float3 {
            var nextTail = nextTail
            for collider in colliders {
                let r = self.radius + collider.radius
                if (nextTail - collider.position).length_squared <= (r * r) {
                    // ヒット。Colliderの半径方向に押し出す
                    let normal = (nextTail - collider.position).normalized
                    let posFromCollider = collider.position + normal * (self.radius + collider.radius)
                    // 長さをboneLengthに強制
                    nextTail = self.node.utx.position + (posFromCollider - self.node.utx.position).normalized * self.length
                }
            }
            return nextTail
        }
        
        func drawGizmo(base: SCNNode, center: SCNNode?, radius: simd_float1, color: UIColor, gizmoNodeName: String) {
            let currentTail = center?.utx.transformPoint(self.currentTail) ?? self.currentTail
            let prevTail = center?.utx.transformPoint(self.prevTail) ?? self.prevTail

            let prevGizmoGeometry = SCNSphere(radius: CGFloat(radius))
            let prevGizmoNode = SCNNode(geometry: prevGizmoGeometry)
            prevGizmoNode.name = gizmoNodeName
            prevGizmoNode.geometry?.firstMaterial?.diffuse.contents = UIColor.gray
            base.addChildNode(prevGizmoNode)
            prevGizmoNode.simdWorldPosition = prevTail
            
            let currentGizmoGeometry = SCNSphere(radius: CGFloat(radius))
            let currentGizmoNode = SCNNode(geometry: currentGizmoGeometry)
            currentGizmoNode.name = gizmoNodeName
            currentGizmoNode.geometry?.firstMaterial?.diffuse.contents = color
            base.addChildNode(currentGizmoNode)
            currentGizmoNode.simdWorldPosition = currentTail
        }
    }
}
