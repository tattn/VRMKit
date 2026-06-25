import SceneKit
import GameKit
import VRMKit
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
final class VRMSpringBone {
    @available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
    struct Collider {
        let head: SIMD3<Float>
        let tail: SIMD3<Float>?
        let radius: Float

        func closestPoint(to point: SIMD3<Float>) -> SIMD3<Float> {
            guard let tail else { return head }
            let segment = tail - head
            let lengthSquared = segment.length_squared
            guard lengthSquared > 0 else { return head }
            let t = max(0, min(1, simd_dot(point - head, segment) / lengthSquared))
            return head + segment * t
        }
    }

    struct JointSetting {
        let stiffnessForce: Float
        let gravityPower: Float
        let gravityDir: SIMD3<Float>
        let dragForce: Float
        let hitRadius: Float

        init(stiffnessForce: Float = 1.0,
             gravityPower: Float = 0.0,
             gravityDir: SIMD3<Float> = .init(0, -1, 0),
             dragForce: Float = 0.4,
             hitRadius: Float = 0.02) {
            self.stiffnessForce = stiffnessForce
            self.gravityPower = gravityPower
            self.gravityDir = gravityDir
            self.dragForce = dragForce
            self.hitRadius = hitRadius
        }

        init(joint: VRM1.SpringBone.Spring.Joint) {
            self.init(stiffnessForce: Float(joint.stiffness ?? 1.0),
                      gravityPower: Float(joint.gravityPower ?? 0.0),
                      gravityDir: SIMD3<Float>(joint.gravityDir, defaultValue: SIMD3<Float>(0, -1, 0)),
                      dragForce: Float(joint.dragForce ?? 0.5),
                      hitRadius: Float(joint.hitRadius ?? 0.02))
        }
    }
    
    public let comment: String?
    public let stiffnessForce: Float
    public let gravityPower: Float
    public let gravityDir: SIMD3<Float>
    public let dragForce: Float
    public let center: SCNNode?
    public let rootBones: [SCNNode]
    public let hitRadius: Float
    
    private var initialLocalRotationMap: [SCNNode : simd_quatf] = [:]
    private let colliderGroups: [VRMSpringBoneColliderGroup]
    private var verlet: [VRMSpringBoneLogic] = []
    private var colliderList: [Collider] = []
    private let jointChain: [SCNNode]?
    private let jointSettings: [ObjectIdentifier: JointSetting]
    
    private let isDrawGizmo: Bool
    
    init(center: SCNNode?,
         rootBones: [SCNNode],
         comment: String? = nil,
         stiffnessForce: Float = 1.0,
         gravityPower: Float = 0.0,
         gravityDir: SIMD3<Float> = .init(0, -1, 0),
         dragForce: Float = 0.4,
         hitRadius: Float = 0.02,
         jointChain: [SCNNode]? = nil,
         jointSettings: [ObjectIdentifier: JointSetting] = [:],
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
        self.jointChain = jointChain
        self.jointSettings = jointSettings
        self.isDrawGizmo = isDrawGizmo
        setup()
    }
    
    private func setup() {
        for kv in self.initialLocalRotationMap {
            kv.key.utx.localRotation = kv.value
        }
        self.initialLocalRotationMap = [:]
        self.verlet = []

        if let jointChain, !jointChain.isEmpty {
            for node in jointChain {
                initialLocalRotationMap[node] = node.utx.localRotation
            }
            setupChain(center, jointChain)
        } else {
            for go in self.rootBones {
                go.enumerateHierarchy { (x, _) in
                    self.initialLocalRotationMap[x] = x.utx.localRotation
                }
                setupRecursive(self.center, go)
            }
        }
    }

    private func setupChain(_ center: SCNNode?, _ joints: [SCNNode]) {
        for index in joints.indices {
            let joint = joints[index]
            let localChildPosition: SIMD3<Float>
            if joints.indices.contains(index + 1) {
                localChildPosition = joint.utx.worldToLocalMatrix.multiplyPoint(joints[index + 1].utx.position)
            } else if let firstChild = joint.childNodes.first {
                localChildPosition = joint.utx.worldToLocalMatrix.multiplyPoint(firstChild.utx.position)
            } else if let parent = joint.parent {
                let delta = joint.utx.position - parent.utx.position
                let direction = delta.length_squared > Float.ulpOfOne ? delta.normalized : SIMD3<Float>(0, -1, 0)
                let childPosition = joint.utx.position + direction * 0.07
                localChildPosition = joint.utx.worldToLocalMatrix.multiplyPoint(childPosition)
            } else {
                continue
            }
            let logic = VRMSpringBoneLogic(center: center, node: joint, localChildPosition: localChildPosition)
            verlet.append(logic)
        }
    }
    
    private func setupRecursive(_ center: SCNNode?, _ parent: SCNNode) {
        if parent.utx.childCount == 0 {
            let delta = parent.utx.position - parent.parent!.utx.position
            let direction = delta.length_squared > Float.ulpOfOne ? delta.normalized : SIMD3<Float>(0, -1, 0)
            let childPosition = parent.utx.position + direction * 0.07
            let logic = VRMSpringBoneLogic(center: center, node: parent, localChildPosition: parent.utx.worldToLocalMatrix.multiplyPoint(childPosition))
            self.verlet.append(logic)
        } else {
            let firstChild = parent.childNodes.first!
            let localChildPosition = parent.utx.worldToLocalMatrix.multiplyPoint(firstChild.utx.position)
            let logic = VRMSpringBoneLogic(center: center, node: parent, localChildPosition: localChildPosition)
            self.verlet.append(logic)
        }

        for child in parent.childNodes {
            self.setupRecursive(center, child)
        }
    }
    
    private func setLocalRotationsIdentity() {
        for verlet in self.verlet {
            verlet.head.utx.localRotation = quat_identity_float
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
                self.colliderList.append(collider.worldCollider)
            }
        }

        for verlet in self.verlet {
            let setting = jointSettings[ObjectIdentifier(verlet.head)] ?? JointSetting(stiffnessForce: stiffnessForce,
                                                                                       gravityPower: gravityPower,
                                                                                       gravityDir: gravityDir,
                                                                                       dragForce: dragForce,
                                                                                       hitRadius: hitRadius)
            let stiffness = setting.stiffnessForce * Float(deltaTime)
            let external = setting.gravityDir * (setting.gravityPower * Float(deltaTime))
            verlet.radius = setting.hitRadius
            verlet.update(
                center: self.center,
                stiffnessForce: stiffness,
                dragForce: setting.dragForce,
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
                    color: .yellow,
                    gizmoNodeName: gizmoNodeName
                )
            }
        }
    }
}

private extension SIMD3 where Scalar == Float {
    init(_ values: [Double]?, defaultValue: SIMD3<Float>) {
        self.init(Float(values?[safe: 0] ?? Double(defaultValue.x)),
                  Float(values?[safe: 1] ?? Double(defaultValue.y)),
                  Float(values?[safe: 2] ?? Double(defaultValue.z)))
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension VRMSpringBone {
    @available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
    class VRMSpringBoneLogic {
        let node: SCNNode
        public var head: SCNNode { self.node }
        private let length: Float
        private var currentTail: SIMD3<Float>
        private var prevTail: SIMD3<Float>
        private let localRotation: simd_quatf
        private let boneAxis: SIMD3<Float>
        private var parentRotation: simd_quatf {
            self.node.parent?.utx.rotation ?? quat_identity_float
        }
        var radius: Float = 0.5
        
        init(center: SCNNode?, node: SCNNode, localChildPosition: SIMD3<Float>) {
            self.node = node
            let worldChildPosition = node.utx.transformPoint(localChildPosition)
            self.currentTail = center?.utx.inverseTransformPoint(worldChildPosition) ?? worldChildPosition
            self.prevTail = self.currentTail
            self.localRotation = node.utx.localRotation
            self.boneAxis = localChildPosition.normalized
            self.length = localChildPosition.length
        }
        
        func update(center: SCNNode?, stiffnessForce: Float, dragForce: Float, external: SIMD3<Float>, colliders: [Collider]) {
            let currentTail: SIMD3<Float> = center?.utx.transformPoint(self.currentTail) ?? self.currentTail
            let prevTail: SIMD3<Float> = center?.utx.transformPoint(self.prevTail) ?? self.prevTail

            // verlet積分で次の位置を計算
            var nextTail: SIMD3<Float> = {
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
        
        private func applyRotation(_ nextTail: SIMD3<Float>) -> simd_quatf {
            let rotation = self.parentRotation * self.localRotation
            return simd_quatf(from: rotation * self.boneAxis, to: nextTail - self.node.utx.position) * rotation
        }
        
        private func collision(_ colliders: [Collider], _ nextTail: SIMD3<Float>) -> SIMD3<Float> {
            var nextTail = nextTail
            for collider in colliders {
                let colliderPosition = collider.closestPoint(to: nextTail)
                let r = self.radius + collider.radius
                if (nextTail - colliderPosition).length_squared <= (r * r) {
                    // ヒット。Colliderの半径方向に押し出す
                    let normal = (nextTail - colliderPosition).normalized
                    let posFromCollider = colliderPosition + normal * (self.radius + collider.radius)
                    // 長さをboneLengthに強制
                    nextTail = self.node.utx.position + (posFromCollider - self.node.utx.position).normalized * self.length
                }
            }
            return nextTail
        }
        
        func drawGizmo(base: SCNNode, center: SCNNode?, radius: simd_float1, color: VRMColor, gizmoNodeName: String) {
            let currentTail = center?.utx.transformPoint(self.currentTail) ?? self.currentTail
            let prevTail = center?.utx.transformPoint(self.prevTail) ?? self.prevTail

            let prevGizmoGeometry = SCNSphere(radius: CGFloat(radius))
            let prevGizmoNode = SCNNode(geometry: prevGizmoGeometry)
            prevGizmoNode.name = gizmoNodeName
            prevGizmoNode.geometry?.firstMaterial?.diffuse.contents = VRMColor.gray
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
