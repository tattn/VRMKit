#if canImport(RealityKit)
import RealityKit
import VRMKit
import VRMKitRuntime
import Foundation

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class VRMEntitySpringBone {
    struct SphereCollider {
        let position: SIMD3<Float>
        let radius: Float
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
    private var colliderList: [SphereCollider] = []

    init(center: Entity?,
         rootBones: [Entity],
         comment: String? = nil,
         stiffnessForce: Float = 1.0,
         gravityPower: Float = 0.0,
         gravityDir: SIMD3<Float> = .init(0, -1, 0),
         dragForce: Float = 0.4,
         hitRadius: Float = 0.02,
         colliderGroups: [VRMEntitySpringBoneColliderGroup] = []) {
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
        for (node, rotation) in initialLocalRotations {
            node.utx.localRotation = rotation
        }
        initialLocalRotations = []
        verlet = []

        for root in rootBones {
            enumerateHierarchy(root) { node in
                initialLocalRotations.append((node, node.utx.localRotation))
            }
            setupRecursive(center, root)
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
            let childPosition = parent.utx.position + delta.normalized * 0.07
            let localChild = parent.utx.worldToLocalMatrix.multiplyPoint(childPosition)
            let logic = VRMEntitySpringBoneLogic(center: center,
                                                 node: parent,
                                                 localChildPosition: localChild)
            verlet.append(logic)
        } else if let firstChild = parent.children.first {
            let localPosition = firstChild.utx.localPosition
            let scale = firstChild.utx.lossyScale
            let logic = VRMEntitySpringBoneLogic(center: center,
                                                 node: parent,
                                                 localChildPosition: SIMD3<Float>(
                                                    localPosition.x * scale.x,
                                                    localPosition.y * scale.y,
                                                    localPosition.z * scale.z
                                                 ))
            verlet.append(logic)
        }

        for child in parent.children {
            setupRecursive(center, child)
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
                colliderList.append(SphereCollider(
                    position: group.node.utx.transformPoint(collider.offset),
                    radius: collider.radius
                ))
            }
        }

        let stiffness = stiffnessForce * Float(deltaTime)
        let external = gravityDir * (gravityPower * Float(deltaTime))

        for logic in verlet {
            logic.radius = hitRadius
            logic.update(center: center,
                         stiffnessForce: stiffness,
                         dragForce: dragForce,
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
                    colliders: [SphereCollider]) {
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

        private func collision(_ colliders: [SphereCollider], _ nextTail: SIMD3<Float>) -> SIMD3<Float> {
            var nextTail = nextTail
            for collider in colliders {
                let r = radius + collider.radius
                if (nextTail - collider.position).length_squared <= (r * r) {
                    let normal = (nextTail - collider.position).normalized
                    let posFromCollider = collider.position + normal * (radius + collider.radius)
                    nextTail = node.utx.position + (posFromCollider - node.utx.position).normalized * length
                }
            }
            return nextTail
        }
    }
}
#endif
