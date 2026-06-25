#if canImport(RealityKit)
import RealityKit
import VRMKit
import VRMKitRuntime
import Foundation

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class VRMEntitySpringBone {
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
    public let center: Entity?
    public let rootBones: [Entity]
    public let hitRadius: Float

    private var initialLocalRotations: [(Entity, simd_quatf)] = []
    private let colliderGroups: [VRMEntitySpringBoneColliderGroup]
    private var verlet: [VRMEntitySpringBoneLogic] = []
    private var colliderList: [Collider] = []
    private let jointChain: [Entity]?
    private let jointSettings: [ObjectIdentifier: JointSetting]

    init(center: Entity?,
         rootBones: [Entity],
         comment: String? = nil,
         stiffnessForce: Float = 1.0,
         gravityPower: Float = 0.0,
         gravityDir: SIMD3<Float> = .init(0, -1, 0),
         dragForce: Float = 0.4,
         hitRadius: Float = 0.02,
         jointChain: [Entity]? = nil,
         jointSettings: [ObjectIdentifier: JointSetting] = [:],
         colliderGroups: [VRMEntitySpringBoneColliderGroup] = []) {
        self.center = center
        self.rootBones = rootBones
        self.comment = comment
        self.stiffnessForce = stiffnessForce
        self.gravityPower = gravityPower
        self.gravityDir = gravityDir
        self.dragForce = dragForce
        self.hitRadius = hitRadius
        self.jointChain = jointChain
        self.jointSettings = jointSettings
        self.colliderGroups = colliderGroups
        setup()
    }

    private func setup() {
        for (node, rotation) in initialLocalRotations {
            node.utx.localRotation = rotation
        }
        initialLocalRotations = []
        verlet = []

        if let jointChain, !jointChain.isEmpty {
            for node in jointChain {
                initialLocalRotations.append((node, node.utx.localRotation))
            }
            setupChain(center, jointChain)
        } else {
            for root in rootBones {
                enumerateHierarchy(root) { node in
                    initialLocalRotations.append((node, node.utx.localRotation))
                }
                setupRecursive(center, root)
            }
        }
    }

    private func enumerateHierarchy(_ node: Entity, _ block: (Entity) -> Void) {
        block(node)
        for child in node.children {
            enumerateHierarchy(child, block)
        }
    }

    private func setupRecursive(_ center: Entity?, _ parent: Entity) {
        if parent.utx.childCount == 0 {
            guard let parentNode = parent.parent else { return }
            let delta = parent.utx.position - parentNode.utx.position
            let direction = delta.length_squared > Float.ulpOfOne ? delta.normalized : SIMD3<Float>(0, -1, 0)
            let childPosition = parent.utx.position + direction * 0.07
            let localChild = parent.utx.worldToLocalMatrix.multiplyPoint(childPosition)
            let logic = VRMEntitySpringBoneLogic(center: center,
                                                 node: parent,
                                                 localChildPosition: localChild)
            verlet.append(logic)
        } else if let firstChild = parent.children.first {
            let localChildPosition = parent.utx.worldToLocalMatrix.multiplyPoint(firstChild.utx.position)
            let logic = VRMEntitySpringBoneLogic(center: center,
                                                 node: parent,
                                                 localChildPosition: localChildPosition)
            verlet.append(logic)
        }

        for child in parent.children {
            setupRecursive(center, child)
        }
    }

    private func setupChain(_ center: Entity?, _ joints: [Entity]) {
        for index in joints.indices {
            let joint = joints[index]
            let localChildPosition: SIMD3<Float>
            if joints.indices.contains(index + 1) {
                localChildPosition = joint.utx.worldToLocalMatrix.multiplyPoint(joints[index + 1].utx.position)
            } else if let firstChild = joint.children.first {
                localChildPosition = joint.utx.worldToLocalMatrix.multiplyPoint(firstChild.utx.position)
            } else if let parent = joint.parent {
                let delta = joint.utx.position - parent.utx.position
                let direction = delta.length_squared > Float.ulpOfOne ? delta.normalized : SIMD3<Float>(0, -1, 0)
                let childPosition = joint.utx.position + direction * 0.07
                localChildPosition = joint.utx.worldToLocalMatrix.multiplyPoint(childPosition)
            } else {
                continue
            }
            let logic = VRMEntitySpringBoneLogic(center: center,
                                                 node: joint,
                                                 localChildPosition: localChildPosition)
            verlet.append(logic)
        }
    }

    func update(deltaTime: TimeInterval) {
        if verlet.isEmpty {
            if rootBones.isEmpty {
                return
            }
            setup()
        }

        colliderList = []
        for group in colliderGroups {
            for collider in group.colliders {
                colliderList.append(collider.worldCollider)
            }
        }

        for logic in verlet {
            let setting = jointSettings[ObjectIdentifier(logic.head)] ?? JointSetting(stiffnessForce: stiffnessForce,
                                                                                      gravityPower: gravityPower,
                                                                                      gravityDir: gravityDir,
                                                                                      dragForce: dragForce,
                                                                                      hitRadius: hitRadius)
            let stiffness = setting.stiffnessForce * Float(deltaTime)
            let external = setting.gravityDir * (setting.gravityPower * Float(deltaTime))
            logic.radius = setting.hitRadius
            logic.update(center: center,
                         stiffnessForce: stiffness,
                         dragForce: setting.dragForce,
                         external: external,
                         colliders: colliderList)
        }
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension VRMEntitySpringBone {
    @MainActor
    final class VRMEntitySpringBoneLogic {
        let node: Entity
        var head: Entity { node }
        private let length: Float
        private var currentTail: SIMD3<Float>
        private var prevTail: SIMD3<Float>
        private let localRotation: simd_quatf
        private let boneAxis: SIMD3<Float>
        private var parentRotation: simd_quatf {
            node.parent?.utx.rotation ?? quat_identity_float
        }
        var radius: Float = 0.5

        init(center: Entity?, node: Entity, localChildPosition: SIMD3<Float>) {
            self.node = node
            let worldChildPosition = node.utx.transformPoint(localChildPosition)
            self.currentTail = center?.utx.inverseTransformPoint(worldChildPosition) ?? worldChildPosition
            self.prevTail = self.currentTail
            self.localRotation = node.utx.localRotation
            self.boneAxis = localChildPosition.normalized
            self.length = localChildPosition.length
        }

        func update(center: Entity?,
                    stiffnessForce: Float,
                    dragForce: Float,
                    external: SIMD3<Float>,
                    colliders: [Collider]) {
            let currentTail: SIMD3<Float> = center?.utx.transformPoint(self.currentTail) ?? self.currentTail
            let prevTail: SIMD3<Float> = center?.utx.transformPoint(self.prevTail) ?? self.prevTail

            var nextTail: SIMD3<Float> = {
                let a = currentTail
                let b = (currentTail - prevTail) * (1.0 - dragForce)
                let c = parentRotation * localRotation * boneAxis * stiffnessForce
                let d = external
                return a + b + c + d
            }()

            nextTail = node.utx.position + (nextTail - node.utx.position).normalized * length
            nextTail = collision(colliders, nextTail)

            self.prevTail = center?.utx.inverseTransformPoint(currentTail) ?? currentTail
            self.currentTail = center?.utx.inverseTransformPoint(nextTail) ?? nextTail

            head.utx.rotation = applyRotation(nextTail)
        }

        private func applyRotation(_ nextTail: SIMD3<Float>) -> simd_quatf {
            let rotation = parentRotation * localRotation
            return simd_quatf(from: rotation * boneAxis, to: nextTail - node.utx.position) * rotation
        }

        private func collision(_ colliders: [Collider], _ nextTail: SIMD3<Float>) -> SIMD3<Float> {
            var nextTail = nextTail
            for collider in colliders {
                let colliderPosition = collider.closestPoint(to: nextTail)
                let r = radius + collider.radius
                if (nextTail - colliderPosition).length_squared <= (r * r) {
                    let normal = (nextTail - colliderPosition).normalized
                    let posFromCollider = colliderPosition + normal * (radius + collider.radius)
                    nextTail = node.utx.position + (posFromCollider - node.utx.position).normalized * length
                }
            }
            return nextTail
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
#endif
