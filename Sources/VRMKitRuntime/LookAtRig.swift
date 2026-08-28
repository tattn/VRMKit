import Foundation
import simd
import VRMKit

/// What a model's gaze follows.
public enum LookAtTarget: Sendable, Equatable {
    /// A point in world space, which the eyes keep on as either it or the model moves.
    case position(SIMD3<Float>)
    /// Angles from the head's forward, in degrees: `yaw` positive toward the model's
    /// left, `pitch` positive up.
    case angles(yaw: Float, pitch: Float)
}

public extension LookAtTarget {
    /// The gaze a rotation states. VRM states one in its own space, where a gaze at rest
    /// looks along +z, so turning that axis by the rotation is what gives the angles.
    static func rotation(_ rotation: simd_quatf) -> LookAtTarget {
        let angles = LookAtAxes.vrm.angles(of: rotation * SIMD3<Float>(0, 0, 1))
        return .angles(yaw: angles.x, pitch: angles.y)
    }
}

/// What one look-at solve produced.
package enum LookAtResult {
    /// The gaze has not moved since the last solve, so nothing was written.
    case unchanged
    /// An eye bone was turned, so a renderer knows its skin pose is stale.
    case posedBones
    /// The look-at expression weights to apply.
    case weights([ExpressionKey: Double])
}

/// The gaze of one model: the angles from the eyes to what they follow, and the eye
/// rotations or expression weights VRM makes of them.
///
/// A bone look-at needs nothing but the eyes, so the rig turns them itself; an
/// expression look-at hands its weights back for the renderer to apply.
package final class LookAtRig<Node: VRMRuntimeNode> where Node.RuntimeNode == Node {
    /// One eye and everything turning it needs, the rest pose read once at set-up.
    private struct Eye {
        let node: Node
        let isLeft: Bool
        let restLocalRotation: simd_quatf
        /// Restates a gaze rotation from the head's frame in this eye's parent's, which
        /// is identity for the eye parented to the head that a VRM rig ordinarily has.
        let headToParent: simd_quatf
        let parentToHead: simd_quatf
    }

    /// What a model stating a look-at gives the rig, held together since a model stating
    /// none has none of it.
    private struct Gaze {
        let plan: VRMLookAtPlan
        let axes: LookAtAxes
        let head: Node
        let eyes: [Eye]
    }

    /// What the eyes follow, nil to leave them at rest. Applied by ``apply()``.
    package var target: LookAtTarget?

    private let gaze: Gaze?
    /// The angles last written out, so a gaze that has not moved is not applied again.
    private var appliedAngles = SIMD2<Float>.zero

    package init() {
        gaze = nil
    }

    private init(gaze: Gaze) {
        self.gaze = gaze
    }

    /// The rig for what `vrm` states, or an empty one for a model that states no look-at.
    /// `node` resolves a glTF node index to the renderer's node.
    package static func make(vrm: VRM, node: (Int) throws -> Node) rethrows -> LookAtRig<Node> {
        try make(plan: VRMLookAtPlan(vrm: vrm), node: node)
    }

    /// The rig for a plan read elsewhere.
    package static func make(plan: VRMLookAtPlan?,
                             node: (Int) throws -> Node) rethrows -> LookAtRig<Node> {
        guard let plan else { return LookAtRig() }
        let head = try node(plan.headNode)
        let headRestWorldRotation = head.worldRotation

        let eyes = try [(plan.leftEyeNode, true), (plan.rightEyeNode, false)]
            .compactMap { index, isLeft -> Eye? in
                guard let index else { return nil }
                let eye = try node(index)
                let parentRestWorldRotation = eye.runtimeParent?.worldRotation ?? quat_identity_float
                let headToParent = (parentRestWorldRotation.conjugate * headRestWorldRotation)
                    .safelyNormalized
                return Eye(node: eye,
                           isLeft: isLeft,
                           restLocalRotation: eye.localRotation,
                           headToParent: headToParent,
                           parentToHead: headToParent.conjugate)
            }
        return LookAtRig(gaze: Gaze(plan: plan,
                                    axes: LookAtAxes(forward: plan.forwardDirection),
                                    head: head,
                                    eyes: eyes))
    }

    /// Aims the gaze at ``target``, turning the eye bones itself where the model states a
    /// bone look-at. A gaze that has not moved since the last call writes nothing.
    package func apply() -> LookAtResult {
        guard let gaze else { return .unchanged }
        let angles = solveAngles(gaze)
        guard angles != appliedAngles else { return .unchanged }
        appliedAngles = angles

        switch gaze.plan.applier {
        case .bone:
            return turnEyes(gaze, yaw: angles.x, pitch: angles.y) ? .posedBones : .unchanged
        case .expression:
            return .weights(expressionWeights(gaze.plan, yaw: angles.x, pitch: angles.y))
        }
    }

    /// The gaze angles in degrees, `x` the yaw toward the model's left and `y` the pitch
    /// up. Zero where nothing is followed, which is what puts the eyes back at rest.
    private func solveAngles(_ gaze: Gaze) -> SIMD2<Float> {
        switch target {
        case nil:
            return .zero
        case .angles(let yaw, let pitch):
            return SIMD2(yaw, pitch)
        case .position(let position):
            let head = gaze.head
            let origin = head.worldMatrix.multiplyPoint(gaze.plan.offsetFromHeadBone)
            let direction = position - origin
            guard direction.length_squared > .ulpOfOne else { return .zero }
            // Measured in the head's own frame, so a turned head leaves the eyes to make
            // up the difference rather than following it twice.
            return gaze.axes.angles(of: head.worldRotation.conjugate * direction)
        }
    }

    /// Turns both eyes, and answers whether either of them actually moved.
    private func turnEyes(_ gaze: Gaze, yaw: Float, pitch: Float) -> Bool {
        let plan = gaze.plan
        // Up and down are the same for either eye; only the horizontal maps swap, an eye
        // turning toward the nose being the inner one.
        let pitchDegrees = Self.map(pitch, positive: plan.verticalUp, negative: plan.verticalDown)
        let pitchRotation = simd_quatf(angle: pitchDegrees * .pi / 180, axis: gaze.axes.right)
        var moved = false
        for eye in gaze.eyes {
            let yawDegrees = eye.isLeft
                ? Self.map(yaw, positive: plan.horizontalOuter, negative: plan.horizontalInner)
                : Self.map(yaw, positive: plan.horizontalInner, negative: plan.horizontalOuter)
            let turn = simd_quatf(angle: yawDegrees * .pi / 180, axis: gaze.axes.up) * pitchRotation
            let rotation = eye.headToParent * turn * eye.parentToHead * eye.restLocalRotation
            if eye.node.setLocalRotationIfMoved(rotation) {
                moved = true
            }
        }
        return moved
    }

    /// The four look-at expressions weighed for this gaze. Both eyes move together, so
    /// the horizontal gaze passes through the outer map whichever way it goes.
    private func expressionWeights(_ plan: VRMLookAtPlan, yaw: Float, pitch: Float) -> [ExpressionKey: Double] {
        func weight(_ value: Float) -> Double { Double(value.clamped(to: 0...1)) }
        return [
            .preset(.lookLeft): yaw > 0 ? weight(plan.horizontalOuter.map(yaw)) : 0,
            .preset(.lookRight): yaw < 0 ? weight(plan.horizontalOuter.map(-yaw)) : 0,
            .preset(.lookUp): pitch > 0 ? weight(plan.verticalUp.map(pitch)) : 0,
            .preset(.lookDown): pitch < 0 ? weight(plan.verticalDown.map(-pitch)) : 0,
        ]
    }

    /// A gaze of `degrees` through whichever map its direction calls for, signed the way
    /// it went in.
    private static func map(_ degrees: Float,
                            positive: VRMLookAtPlan.RangeMap,
                            negative: VRMLookAtPlan.RangeMap) -> Float {
        degrees >= 0 ? positive.map(degrees) : -negative.map(-degrees)
    }
}

/// The axes a gaze is measured and turned about, from the way a model faces: VRM 0.x and
/// VRM 1.0 face opposite ways, and loading converts no coordinates.
struct LookAtAxes {
    /// The space VRM states a gaze in, which faces the way a VRM 1.0 model does.
    static let vrm = LookAtAxes(forward: SIMD3<Float>(0, 0, 1))

    let forward: SIMD3<Float>
    let up = SIMD3<Float>(0, 1, 0)
    /// The model's own left, which a positive yaw turns toward.
    let left: SIMD3<Float>
    /// The model's own right, which a positive pitch turns about.
    var right: SIMD3<Float> { -left }

    init(forward: SIMD3<Float>) {
        self.forward = forward
        left = simd_cross(SIMD3<Float>(0, 1, 0), forward)
    }

    /// What `direction` reads as in degrees, `x` the yaw toward the model's left and `y`
    /// the pitch up. A direction of nothing reads as a gaze straight ahead.
    func angles(of direction: SIMD3<Float>) -> SIMD2<Float> {
        guard direction.length_squared > .ulpOfOne else { return .zero }
        let gaze = direction.normalized
        let yaw = atan2(simd_dot(gaze, left), simd_dot(gaze, forward))
        let pitch = asin(simd_dot(gaze, up).clamped(to: -1...1))
        return SIMD2(yaw, pitch) * (180 / .pi)
    }
}
