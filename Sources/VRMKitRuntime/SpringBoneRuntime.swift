import simd
import VRMKit

/// A collider where it is this frame, in world space.
package struct SpringBoneCollider {
    package enum Kind: Equatable {
        /// Keeps joints out of the sphere or capsule.
        case outside
        /// Keeps joints in the sphere or capsule (`VRMC_springBone_extended_collider`).
        case inside
        /// Keeps joints on the side of the plane through `head` the normal points to
        /// (`VRMC_springBone_extended_collider`).
        case plane(normal: SIMD3<Float>)
    }

    package let head: SIMD3<Float>
    let tail: SIMD3<Float>?
    package let radius: Float
    let kind: Kind

    package init(head: SIMD3<Float>, tail: SIMD3<Float>?, radius: Float, kind: Kind = .outside) {
        self.head = head
        self.tail = tail
        self.radius = radius
        self.kind = kind
    }

    package func closestPoint(to point: SIMD3<Float>) -> SIMD3<Float> {
        guard let tail else { return head }
        let segment = tail - head
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > Float.ulpOfOne else { return head }
        let t = max(0, min(1, simd_dot(point - head, segment) / lengthSquared))
        return head + segment * t
    }

    /// How far a joint of `hitRadius` at `point` is clear of the collider, negative when
    /// they overlap, and the direction that clears it, as the `VRMC_springBone` and
    /// `VRMC_springBone_extended_collider` reference implementations measure them.
    func separation(of point: SIMD3<Float>, hitRadius: Float) -> (distance: Float, direction: SIMD3<Float>) {
        switch kind {
        case .outside:
            let delta = point - closestPoint(to: point)
            let length = simd_length(delta)
            // A point exactly on the collider has no direction of its own to be pushed along.
            let direction = length > Float.ulpOfOne ? delta / length : SIMD3<Float>(0, 1, 0)
            return (length - radius - hitRadius, direction)
        case .inside:
            let delta = point - closestPoint(to: point)
            let length = simd_length(delta)
            let direction = length > Float.ulpOfOne ? -delta / length : SIMD3<Float>(0, -1, 0)
            return (radius - hitRadius - length, direction)
        case .plane(let normal):
            return (simd_dot(point - head, normal) - hitRadius, normal)
        }
    }
}

/// A collider as either version states one: a shape in the space of the node it hangs
/// off. Only the renderer holds the scene graph, so it hands ``world(in:)`` the
/// node's transform.
package enum SpringBoneColliderShape: Equatable {
    case sphere(offset: SIMD3<Float>, radius: Float, inside: Bool = false)
    case capsule(offset: SIMD3<Float>, tail: SIMD3<Float>, radius: Float, inside: Bool = false)
    /// `normal` is a unit vector.
    case plane(offset: SIMD3<Float>, normal: SIMD3<Float>)

    package init(vrm0Collider collider: VRM0.SecondaryAnimation.ColliderGroup.Collider) throws {
        let offset = VRM0.nodeSpace(collider.offset)
        let radius = Float(collider.radius)
        try VRMSpringBoneParameters.requireFinite(offset, named: "collider offset")
        try VRMSpringBoneParameters.requireFiniteNonnegative(radius, named: "collider radius")
        self = .sphere(offset: offset, radius: radius)
    }

    /// The shape `VRMC_springBone_extended_collider` gives the collider when it carries
    /// one, which replaces the fallback shape `VRMC_springBone` states.
    package init(vrm1Collider collider: VRM1.SpringBone.Collider) throws {
        if let extended = try collider.extendedShape() {
            switch extended {
            case .sphere(let offset, let radius, let inside):
                self = try Self.validatedSphere(offset: offset, radius: radius, inside: inside)
            case .capsule(let offset, let tail, let radius, let inside):
                self = try Self.validatedCapsule(offset: offset, tail: tail, radius: radius, inside: inside)
            case .plane(let offset, let normal):
                try VRMSpringBoneParameters.requireFinite(offset, named: "collider offset")
                try VRMSpringBoneParameters.requireFinite(normal, named: "collider normal")
                guard simd_length_squared(normal) > Float.ulpOfOne else {
                    throw VRMError._dataInconsistent("a plane collider has no normal")
                }
                self = .plane(offset: offset, normal: simd_normalize(normal))
            }
            return
        }
        switch collider.shape {
        case .sphere(let sphere):
            self = try Self.validatedSphere(offset: sphere.offset, radius: Float(sphere.radius), inside: false)
        case .capsule(let capsule):
            self = try Self.validatedCapsule(offset: capsule.offset,
                                             tail: capsule.tail,
                                             radius: Float(capsule.radius),
                                             inside: false)
        }
    }

    private static func validatedSphere(offset: SIMD3<Float>, radius: Float, inside: Bool) throws -> Self {
        try VRMSpringBoneParameters.requireFinite(offset, named: "collider offset")
        try VRMSpringBoneParameters.requireFiniteNonnegative(radius, named: "collider radius")
        return .sphere(offset: offset, radius: radius, inside: inside)
    }

    private static func validatedCapsule(offset: SIMD3<Float>,
                                         tail: SIMD3<Float>,
                                         radius: Float,
                                         inside: Bool) throws -> Self {
        try VRMSpringBoneParameters.requireFinite(offset, named: "collider offset")
        try VRMSpringBoneParameters.requireFinite(tail, named: "collider tail")
        try VRMSpringBoneParameters.requireFiniteNonnegative(radius, named: "collider radius")
        return .capsule(offset: offset, tail: tail, radius: radius, inside: inside)
    }

    /// Where the shape is, given where the node it hangs off is.
    package func world(in localToWorld: simd_float4x4) -> SpringBoneCollider {
        switch self {
        case .sphere(let offset, let radius, let inside):
            SpringBoneCollider(head: localToWorld.multiplyPoint(offset),
                               tail: nil,
                               radius: radius,
                               kind: inside ? .inside : .outside)
        case .capsule(let offset, let tail, let radius, let inside):
            SpringBoneCollider(head: localToWorld.multiplyPoint(offset),
                               tail: localToWorld.multiplyPoint(tail),
                               radius: radius,
                               kind: inside ? .inside : .outside)
        case .plane(let offset, let normal):
            SpringBoneCollider(head: localToWorld.multiplyPoint(offset),
                               tail: nil,
                               radius: 0,
                               kind: .plane(normal: Self.worldNormal(normal, in: localToWorld)))
        }
    }

    /// A normal turned by the inverse transpose, so it stays perpendicular to the plane
    /// under a node scaled unevenly.
    private static func worldNormal(_ normal: SIMD3<Float>, in localToWorld: simd_float4x4) -> SIMD3<Float> {
        let columns = localToWorld.columns
        let linear = simd_float3x3(SIMD3(columns.0.x, columns.0.y, columns.0.z),
                                   SIMD3(columns.1.x, columns.1.y, columns.1.z),
                                   SIMD3(columns.2.x, columns.2.y, columns.2.z))
        let world = linear.inverse.transpose * normal
        return simd_length_squared(world) > Float.ulpOfOne ? simd_normalize(world) : normal
    }
}

/// What one joint swings like. VRM 0.x gives a whole bone group one setting and VRM 1.0
/// gives every joint its own, and the two disagree about a missing field, so nothing
/// is defaulted here.
package struct SpringBoneJointSetting {
    let stiffnessForce: Float
    let gravityPower: Float
    let gravityDir: SIMD3<Float>
    let dragForce: Float
    let hitRadius: Float
    /// The range the joint swings in (`VRMC_springBone_limit`), nil for anywhere.
    let limit: SpringBoneLimit?

    package init(stiffnessForce: Float,
                 gravityPower: Float,
                 gravityDir: SIMD3<Float>,
                 dragForce: Float,
                 hitRadius: Float,
                 limit: SpringBoneLimit? = nil) {
        self.stiffnessForce = stiffnessForce
        self.gravityPower = gravityPower
        self.gravityDir = gravityDir
        self.dragForce = dragForce
        self.hitRadius = hitRadius
        self.limit = limit
    }

    package init(vrm0BoneGroup group: VRM0.SecondaryAnimation.BoneGroup) throws {
        self.init(stiffnessForce: Float(group.stiffness),
                  gravityPower: Float(group.gravityPower),
                  gravityDir: VRM0.nodeSpace(group.gravityDir),
                  dragForce: Float(group.dragForce),
                  hitRadius: Float(group.hitRadius))
        try validate()
    }

    /// Fills in what the joint leaves out with the `VRMC_springBone` defaults.
    package init(vrm1Joint joint: VRM1.SpringBone.Spring.Joint) throws {
        self.init(stiffnessForce: joint.stiffness.map(Float.init) ?? VRMSpringBoneDefaults.stiffness,
                  gravityPower: joint.gravityPower.map(Float.init) ?? VRMSpringBoneDefaults.gravityPower,
                  gravityDir: joint.gravityDir,
                  dragForce: joint.dragForce.map(Float.init) ?? VRMSpringBoneDefaults.dragForce,
                  hitRadius: joint.hitRadius.map(Float.init) ?? VRMSpringBoneDefaults.hitRadius,
                  limit: try joint.limit().map(SpringBoneLimit.init(vrm1Limit:)))
        try validate()
    }

    /// Refuses what the simulation cannot swing, so everything below
    /// ``SpringBoneRig/make(vrm:node:)`` works on values it can trust.
    private func validate() throws {
        try VRMSpringBoneParameters.requireFiniteNonnegative(stiffnessForce, named: "stiffness")
        try VRMSpringBoneParameters.requireFiniteNonnegative(gravityPower, named: "gravity power")
        try VRMSpringBoneParameters.requireFiniteNonnegative(hitRadius, named: "hit radius")
        try VRMSpringBoneParameters.requireDragForce(dragForce)
        try VRMSpringBoneParameters.requireFinite(gravityDir, named: "gravity direction")
    }
}

/// The node a spring measures its motion against, so moving the model itself does not
/// swing what hangs off it. Held as a transform, so the inverse is taken once a frame
/// rather than once per tail position.
package struct SpringBoneCenter {
    private let localToWorld: simd_float4x4
    private let worldToLocal: simd_float4x4

    package init(localToWorld: simd_float4x4) {
        self.localToWorld = localToWorld
        self.worldToLocal = localToWorld.inverse
    }

    func world(_ position: SIMD3<Float>) -> SIMD3<Float> {
        localToWorld.multiplyPoint(position)
    }

    func centered(_ position: SIMD3<Float>) -> SIMD3<Float> {
        worldToLocal.multiplyPoint(position)
    }
}

/// One head and tail pair of a spring: the joint that swings, and the state carried
/// from frame to frame. The scene graph stays outside, so the renderer swings a
/// bone the same way.
package struct SpringBoneJoint {
    /// Where the tail lies at rest, in the joint's own space: where the stiffness pulls it.
    let boneAxis: SIMD3<Float>

    /// How far the tail is at rest, in world space as `VRMC_springBone` has it, so a
    /// scaled joint swings the length it is drawn at.
    let boneLength: Float

    private let initialLocalRotation: simd_quatf
    /// Both in the center's space, which is where they stay between frames.
    private var currentTail: SIMD3<Float>
    private var prevTail: SIMD3<Float>

    /// Nil for a pair with no length to swing on: normalizing it would put NaN through
    /// the simulation.
    package init?(head: SIMD3<Float>,
                  localTail: SIMD3<Float>,
                  worldTail: SIMD3<Float>,
                  initialLocalRotation: simd_quatf,
                  center: SpringBoneCenter?) {
        let boneLength = simd_distance(worldTail, head)
        guard boneLength > Float.ulpOfOne, localTail.length_squared > Float.ulpOfOne else { return nil }
        self.boneAxis = localTail.normalized
        self.boneLength = boneLength
        self.initialLocalRotation = initialLocalRotation
        self.currentTail = center?.centered(worldTail) ?? worldTail
        self.prevTail = self.currentTail
    }

    /// The rotation the joint's node was authored with, which a reset puts back.
    var restLocalRotation: simd_quatf { initialLocalRotation }

    /// Puts the tail where the joint points when turned to the world `rotation`, carrying
    /// no motion into the next step: at rest, so a teleported model does not read the jump
    /// as a swing, or where a paused joint was held, so it swings on from that shape.
    package mutating func hold(head: SIMD3<Float>,
                               rotation: simd_quatf,
                               center: SpringBoneCenter?) {
        let tail = head + (rotation * boneAxis) * boneLength
        currentTail = center?.centered(tail) ?? tail
        prevTail = currentTail
    }

    /// Advances the tail by `deltaTime` and returns the world rotation the joint has to
    /// take for its bone to point at it.
    package mutating func update(deltaTime: Float,
                                 setting: SpringBoneJointSetting,
                                 head: SIMD3<Float>,
                                 parentRotation: simd_quatf,
                                 center: SpringBoneCenter?,
                                 colliders: [SpringBoneCollider],
                                 externalForce: SIMD3<Float> = .zero) -> simd_quatf {
        let restRotation = parentRotation * initialLocalRotation
        let restDirection = restRotation * boneAxis
        let currentTail = center?.world(self.currentTail) ?? self.currentTail
        let prevTail = center?.world(self.prevTail) ?? self.prevTail

        // Verlet integration: the tail carries on last frame's move, damped by the drag,
        // while the stiffness pulls it back to the rest pose.
        let inertia = (currentTail - prevTail) * (1 - setting.dragForce)
        let stiffness = restDirection * (setting.stiffnessForce * deltaTime)
        let external = (setting.gravityDir * setting.gravityPower + externalForce) * deltaTime
        // The limit keeps the tail in range after the inertia and again after every
        // collider pushes it, as `VRMC_springBone_limit` orders them.
        let limitSpace = setting.limit?.space(restRotation: restRotation, boneAxis: boneAxis)
        func limited(_ tail: SIMD3<Float>) -> SIMD3<Float> {
            guard let limit = setting.limit, let limitSpace else { return tail }
            let direction = limitSpace.inverse.act((tail - head) / boneLength)
            return head + limitSpace.act(limit.constrained(direction)) * boneLength
        }

        var nextTail = limited(onBone(currentTail + inertia + stiffness + external,
                                      head: head,
                                      restDirection: restDirection))

        for collider in colliders {
            let (distance, direction) = collider.separation(of: nextTail, hitRadius: setting.hitRadius)
            guard distance <= 0 else { continue }
            nextTail = limited(onBone(nextTail - direction * distance, head: head, restDirection: restDirection))
        }

        self.prevTail = center?.centered(currentTail) ?? currentTail
        self.currentTail = center?.centered(nextTail) ?? nextTail

        // `onBone` puts the tail exactly `boneLength` away, so dividing by it normalizes
        // without the square root `simd_quatf(from:to:)` needs.
        return simd_quatf(from: restDirection, to: (nextTail - head) / boneLength) * restRotation
    }

    /// `tail` pulled back onto the sphere the bone reaches, holding it at its authored length.
    private func onBone(_ tail: SIMD3<Float>,
                        head: SIMD3<Float>,
                        restDirection: SIMD3<Float>) -> SIMD3<Float> {
        let delta = tail - head
        let direction = delta.length_squared > Float.ulpOfOne ? delta.normalized : restDirection
        return head + direction * boneLength
    }
}

/// The tail VRM 0.x swings a childless bone around: 7cm on in the direction it points.
func springBoneLeafTail(head: SIMD3<Float>, parent: SIMD3<Float>) -> SIMD3<Float> {
    let delta = head - parent
    let direction = delta.length_squared > Float.ulpOfOne ? delta.normalized : SIMD3<Float>(0, -1, 0)
    return head + direction * 0.07
}
