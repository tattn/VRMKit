import Foundation
import simd

/// One `VRMC_springBone` spring, as an edit adds it to a VRM 1.0 model.
///
/// A spring swings each joint towards the next, so the last is a tail rather than
/// a joint that swings, and its parameters go unread. ``VRM0SpringBoneGroup`` is
/// the shape VRM 0.x describes a swing in.
public struct VRM1Spring: Equatable, Sendable {
    /// The joints the swing runs through, each below the one before it. A node
    /// skipped between two of them belongs to the chain all the same, so no other
    /// spring may name it.
    public var joints: [VRM1SpringJoint]
    public var name: String?
    /// The node the swing is measured against, so that carrying the model across
    /// the world does not fling what hangs off it. It is the first joint or one of
    /// its ancestors, and never a node another spring swings.
    public var center: Int?
    /// The collider groups the spring is kept out of. Authoring colliders is
    /// not part of this.
    public var colliderGroups: [Int]

    public init(joints: [VRM1SpringJoint],
                name: String? = nil,
                center: Int? = nil,
                colliderGroups: [Int] = []) {
        self.joints = joints
        self.name = name
        self.center = center
        self.colliderGroups = colliderGroups
    }

    /// A spring whose joints all swing alike, which is how a merged prop is
    /// usually given its motion. The parameters go to every node but the last,
    /// which is left the bare tail it is read as.
    public init(joints nodes: [Int],
                stiffness: Float? = nil,
                gravityPower: Float? = nil,
                gravityDirection: SIMD3<Float>? = nil,
                dragForce: Float? = nil,
                hitRadius: Float? = nil,
                name: String? = nil,
                center: Int? = nil,
                colliderGroups: [Int] = []) {
        self.init(joints: nodes.enumerated().map { index, node in
            guard index < nodes.count - 1 else { return VRM1SpringJoint(node: node) }
            return VRM1SpringJoint(node: node,
                                   stiffness: stiffness,
                                   gravityPower: gravityPower,
                                   gravityDirection: gravityDirection,
                                   dragForce: dragForce,
                                   hitRadius: hitRadius)
        }, name: name, center: center, colliderGroups: colliderGroups)
    }
}

/// One node of a ``VRM1Spring``, and how it swings.
///
/// VRM 1.0 states the parameters per joint, so a chain may stiffen towards its
/// root the way hair does. A nil is left out of the file, which
/// `VRMC_springBone` reads as ``VRMSpringBoneDefaults`` states.
public struct VRM1SpringJoint: Equatable, Sendable {
    public var node: Int
    /// How strongly the joint returns to the pose it was authored in.
    public var stiffness: Float?
    /// How hard gravity pulls along ``gravityDirection``.
    public var gravityPower: Float?
    public var gravityDirection: SIMD3<Float>?
    /// How much of the joint's motion is lost each frame: 1 stops it dead.
    public var dragForce: Float?
    /// The radius the joint is kept off a collider by.
    public var hitRadius: Float?

    public init(node: Int,
                stiffness: Float? = nil,
                gravityPower: Float? = nil,
                gravityDirection: SIMD3<Float>? = nil,
                dragForce: Float? = nil,
                hitRadius: Float? = nil) {
        self.node = node
        self.stiffness = stiffness
        self.gravityPower = gravityPower
        self.gravityDirection = gravityDirection
        self.dragForce = dragForce
        self.hitRadius = hitRadius
    }
}

extension VRM1Spring {
    func json() -> JSONObject {
        var spring: JSONObject = ["joints": .objects(joints.map { $0.json() })]
        spring.set("name", name)
        spring.set("center", center)
        if !colliderGroups.isEmpty {
            spring["colliderGroups"] = .numbers(colliderGroups)
        }
        return spring
    }
}

extension VRM1SpringJoint {
    func json() -> JSONObject {
        var joint: JSONObject = ["node": .int(node)]
        joint.set("hitRadius", hitRadius)
        joint.set("stiffness", stiffness)
        joint.set("gravityPower", gravityPower)
        joint.set("gravityDir", gravityDirection.map { [$0.x, $0.y, $0.z] })
        joint.set("dragForce", dragForce)
        return joint
    }

    /// The parameters the joint states that have to be finite and nonnegative.
    var statedParameters: [(name: String, value: Float)] {
        [("stiffness", stiffness), ("gravity power", gravityPower), ("hit radius", hitRadius)]
            .compactMap { name, value in value.map { (name, $0) } }
    }
}
