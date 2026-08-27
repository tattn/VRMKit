import simd
import VRMKit

package struct SpringBoneCollider {
    package let head: SIMD3<Float>
    package let tail: SIMD3<Float>?
    package let radius: Float

    package init(head: SIMD3<Float>, tail: SIMD3<Float>?, radius: Float) {
        self.head = head
        self.tail = tail
        self.radius = radius
    }

    package func closestPoint(to point: SIMD3<Float>) -> SIMD3<Float> {
        guard let tail else { return head }
        let segment = tail - head
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > Float.ulpOfOne else { return head }
        let t = max(0, min(1, simd_dot(point - head, segment) / lengthSquared))
        return head + segment * t
    }
}

/// A collider as either version states one: a shape in the space of the node it hangs
/// off. Only the renderer holds the scene graph, so it hands ``world(in:)`` the
/// node's transform.
package enum SpringBoneColliderShape: Equatable {
    case sphere(offset: SIMD3<Float>, radius: Float)
    case capsule(offset: SIMD3<Float>, tail: SIMD3<Float>, radius: Float)

    package init(vrm0Collider collider: VRM0.SecondaryAnimation.ColliderGroup.Collider) throws {
        let offset = collider.offset
        let radius = Float(collider.radius)
        try VRMSpringBoneParameters.requireFinite(offset, named: "collider offset")
        try VRMSpringBoneParameters.requireFiniteNonnegative(radius, named: "collider radius")
        self = .sphere(offset: offset, radius: radius)
    }

    package init(vrm1Collider collider: VRM1.SpringBone.Collider) throws {
        switch collider.shape {
        case .sphere(let sphere):
            let offset = sphere.offset
            let radius = Float(sphere.radius)
            try VRMSpringBoneParameters.requireFinite(offset, named: "collider offset")
            try VRMSpringBoneParameters.requireFiniteNonnegative(radius, named: "collider radius")
            self = .sphere(offset: offset, radius: radius)
        case .capsule(let capsule):
            let offset = capsule.offset
            let tail = capsule.tail
            let radius = Float(capsule.radius)
            try VRMSpringBoneParameters.requireFinite(offset, named: "collider offset")
            try VRMSpringBoneParameters.requireFinite(tail, named: "collider tail")
            try VRMSpringBoneParameters.requireFiniteNonnegative(radius, named: "collider radius")
            self = .capsule(offset: offset, tail: tail, radius: radius)
        }
    }

    /// Where the shape is, given where the node it hangs off is.
    package func world(in localToWorld: simd_float4x4) -> SpringBoneCollider {
        switch self {
        case .sphere(let offset, let radius):
            SpringBoneCollider(head: localToWorld.multiplyPoint(offset), tail: nil, radius: radius)
        case .capsule(let offset, let tail, let radius):
            SpringBoneCollider(head: localToWorld.multiplyPoint(offset),
                               tail: localToWorld.multiplyPoint(tail),
                               radius: radius)
        }
    }
}

/// What one joint swings like. VRM 0.x gives a whole bone group one setting and VRM 1.0
/// gives every joint its own, and the two disagree about a missing field, so nothing
/// is defaulted here.
package struct SpringBoneJointSetting {
    package let stiffnessForce: Float
    package let gravityPower: Float
    package let gravityDir: SIMD3<Float>
    package let dragForce: Float
    package let hitRadius: Float

    package init(stiffnessForce: Float,
                 gravityPower: Float,
                 gravityDir: SIMD3<Float>,
                 dragForce: Float,
                 hitRadius: Float) {
        self.stiffnessForce = stiffnessForce
        self.gravityPower = gravityPower
        self.gravityDir = gravityDir
        self.dragForce = dragForce
        self.hitRadius = hitRadius
    }

    package init(vrm0BoneGroup group: VRM0.SecondaryAnimation.BoneGroup) throws {
        self.init(stiffnessForce: Float(group.stiffness),
                  gravityPower: Float(group.gravityPower),
                  gravityDir: group.gravityDir,
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
                  hitRadius: joint.hitRadius.map(Float.init) ?? VRMSpringBoneDefaults.hitRadius)
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
/// from frame to frame. The scene graph stays outside, so both renderers swing a
/// bone the same way.
package struct SpringBoneJoint {
    /// Where the tail lies at rest, in the joint's own space: where the stiffness pulls it.
    package let boneAxis: SIMD3<Float>

    /// How far the tail is at rest, in world space as `VRMC_springBone` has it, so a
    /// scaled joint swings the length it is drawn at.
    package let boneLength: Float

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
    package var restLocalRotation: simd_quatf { initialLocalRotation }

    /// Puts the tail back at rest, carrying no motion into the next step, so a
    /// teleported model does not read the jump as a swing.
    package mutating func settle(head: SIMD3<Float>,
                                 parentRotation: simd_quatf,
                                 center: SpringBoneCenter?) {
        let restDirection = (parentRotation * initialLocalRotation) * boneAxis
        let tail = head + restDirection * boneLength
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
        var nextTail = onBone(currentTail + inertia + stiffness + external,
                              head: head,
                              restDirection: restDirection)

        for collider in colliders {
            let closest = collider.closestPoint(to: nextTail)
            let delta = nextTail - closest
            let distance = setting.hitRadius + collider.radius
            guard delta.length_squared <= distance * distance else { continue }
            // Hit, so push the tail out along the collider's radius.
            let normal = delta.length_squared > Float.ulpOfOne ? delta.normalized : SIMD3<Float>(0, 1, 0)
            nextTail = onBone(closest + normal * distance, head: head, restDirection: restDirection)
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
package func springBoneLeafTail(head: SIMD3<Float>, parent: SIMD3<Float>) -> SIMD3<Float> {
    let delta = head - parent
    let direction = delta.length_squared > Float.ulpOfOne ? delta.normalized : SIMD3<Float>(0, -1, 0)
    return head + direction * 0.07
}
