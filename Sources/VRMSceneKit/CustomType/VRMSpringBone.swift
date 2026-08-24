import SceneKit
import VRMKit
import VRMKitRuntime

/// One spring: the joints it swings, and the colliders they are kept out of.
/// The simulation itself is ``SpringBoneJoint``, shared with the RealityKit renderer.
@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
final class VRMSpringBone {
    private let center: SCNNode?
    private let colliderGroups: [VRMSpringBoneColliderGroup]
    /// Built once: nothing adds a bone to a model after it is loaded.
    private var joints: [Joint]
    private var colliders: [SpringBoneCollider] = []

    private struct Joint {
        let node: SCNNode
        let setting: SpringBoneJointSetting
        var state: SpringBoneJoint
    }

    /// A VRM 0.x bone group: every bone below each root swings, on the one
    /// setting the group states.
    init(center: SCNNode?,
         rootBones: [SCNNode],
         setting: SpringBoneJointSetting,
         colliderGroups: [VRMSpringBoneColliderGroup]) {
        self.center = center
        self.colliderGroups = colliderGroups

        let centerTransform = Self.centerTransform(center)
        var joints: [Joint] = []
        for root in rootBones {
            Self.appendJoints(below: root, setting: setting, center: centerTransform, to: &joints)
        }
        self.joints = joints
    }

    /// A VRM 1.0 spring: each consecutive pair of the chain is one joint that
    /// swings, so `a-b-c-d` is `a-b`, `b-c` and `c-d`. The last of the chain is
    /// only a tail, and a chain of one swings nothing.
    init(center: SCNNode?,
         chain: [(node: SCNNode, setting: SpringBoneJointSetting)],
         colliderGroups: [VRMSpringBoneColliderGroup]) {
        self.center = center
        self.colliderGroups = colliderGroups

        let centerTransform = Self.centerTransform(center)
        self.joints = zip(chain, chain.dropFirst()).compactMap { head, tail in
            Self.joint(node: head.node,
                       tail: tail.node.utx.position,
                       setting: head.setting,
                       center: centerTransform)
        }
    }

    private static func centerTransform(_ center: SCNNode?) -> SpringBoneCenter? {
        center.map { SpringBoneCenter(localToWorld: $0.utx.localToWorldMatrix) }
    }

    /// VRM 0.x swings every bone below the root: one with children towards the
    /// first of them, and a leaf towards the tail VRM 0.x gives it.
    private static func appendJoints(below node: SCNNode,
                                     setting: SpringBoneJointSetting,
                                     center: SpringBoneCenter?,
                                     to joints: inout [Joint]) {
        let tail: SIMD3<Float>?
        if let firstChild = node.childNodes.first {
            tail = firstChild.utx.position
        } else if let parent = node.parent {
            tail = springBoneLeafTail(head: node.utx.position, parent: parent.utx.position)
        } else {
            tail = nil
        }
        if let tail, let joint = joint(node: node, tail: tail, setting: setting, center: center) {
            joints.append(joint)
        }

        for child in node.childNodes {
            appendJoints(below: child, setting: setting, center: center, to: &joints)
        }
    }

    private static func joint(node: SCNNode,
                              tail: SIMD3<Float>,
                              setting: SpringBoneJointSetting,
                              center: SpringBoneCenter?) -> Joint? {
        guard let state = SpringBoneJoint(head: node.utx.position,
                                          localTail: node.utx.worldToLocalMatrix.multiplyPoint(tail),
                                          worldTail: tail,
                                          initialLocalRotation: node.utx.localRotation,
                                          center: center) else { return nil }
        return Joint(node: node, setting: setting, state: state)
    }

    func update(deltaTime: TimeInterval) {
        guard !joints.isEmpty else { return }

        colliders.removeAll(keepingCapacity: true)
        for group in colliderGroups {
            for collider in group.colliders {
                colliders.append(collider.worldCollider)
            }
        }

        let centerTransform = Self.centerTransform(center)
        for index in joints.indices {
            let node = joints[index].node
            let rotation = joints[index].state.update(
                deltaTime: Float(deltaTime),
                setting: joints[index].setting,
                head: node.utx.position,
                parentRotation: node.parent?.utx.rotation ?? quat_identity_float,
                center: centerTransform,
                colliders: colliders
            )
            node.utx.setRotation(rotation)
        }
    }
}
