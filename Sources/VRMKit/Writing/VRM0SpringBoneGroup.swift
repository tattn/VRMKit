import Foundation
import simd

/// One VRM 0.x bone group, as an edit adds it to a model.
///
/// VRM 0.x names the nodes a swing starts at and swings everything below each of them,
/// on the one set of parameters the group states. ``VRM1Spring`` is the VRM 1.0 shape.
public struct VRM0SpringBoneGroup: Equatable, Sendable {
    public var rootBones: [GLTFNodeIndex]
    /// How strongly a bone returns to the pose it was authored in.
    public var stiffness: Float
    /// How hard gravity pulls along ``gravityDirection``.
    public var gravityPower: Float
    public var gravityDirection: SIMD3<Float>
    /// How much of a bone's motion is lost each frame: 1 stops it dead.
    public var dragForce: Float
    /// The radius the bone is kept off a collider by.
    public var hitRadius: Float
    /// The collider groups the swing is kept out of. Colliders are not authored here.
    public var colliderGroups: [Int]
    /// The node the swing is measured against, so moving the model does not fling
    /// what hangs off it.
    public var center: GLTFNodeIndex?
    /// What the group is called, which VRM 0.x keeps as a comment.
    public var comment: String?

    public init(rootBones: [GLTFNodeIndex],
                stiffness: Float = VRMSpringBoneDefaults.stiffness,
                gravityPower: Float = VRMSpringBoneDefaults.gravityPower,
                gravityDirection: SIMD3<Float> = VRMSpringBoneDefaults.gravityDirection,
                dragForce: Float = VRMSpringBoneDefaults.dragForce,
                hitRadius: Float = VRMSpringBoneDefaults.hitRadius,
                colliderGroups: [Int] = [],
                center: GLTFNodeIndex? = nil,
                comment: String? = nil) {
        self.rootBones = rootBones
        self.stiffness = stiffness
        self.gravityPower = gravityPower
        self.gravityDirection = gravityDirection
        self.dragForce = dragForce
        self.hitRadius = hitRadius
        self.colliderGroups = colliderGroups
        self.center = center
        self.comment = comment
    }
}

extension VRM0SpringBoneGroup {
    /// The group as VRM 0.x writes one. `center` is -1 where there is none, in a field
    /// 0.x always writes.
    func json() -> JSONObject {
        var group: JSONObject = [
            "bones": .numbers(rootBones.map(\.rawValue)),
            "center": .int(center?.rawValue ?? -1),
            "colliderGroups": .numbers(colliderGroups),
            "dragForce": .number(dragForce),
            "gravityDir": ["x": .number(gravityDirection.x),
                           "y": .number(gravityDirection.y),
                           "z": .number(gravityDirection.z)],
            "gravityPower": .number(gravityPower),
            "hitRadius": .number(hitRadius),
            // 0.x really does spell it this way.
            "stiffiness": .number(stiffness),
        ]
        group.set("comment", comment)
        return group
    }
}
