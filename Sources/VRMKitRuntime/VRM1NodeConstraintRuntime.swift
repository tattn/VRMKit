import simd
import VRMKit

package enum VRMNodeConstraintDescriptor {
    case roll(source: Int, axis: RollAxis, weight: Float)
    case aim(source: Int, axis: AimAxis, weight: Float)
    case rotation(source: Int, weight: Float)

    package enum RollAxis {
        case x
        case y
        case z
    }

    package enum AimAxis {
        case positiveX
        case negativeX
        case positiveY
        case negativeY
        case positiveZ
        case negativeZ
    }

    package init?(_ constraint: GLTF.Node.NodeExtensions.NodeConstraint.Constraint) {
        if let roll = constraint.roll {
            self = .roll(source: roll.source,
                         axis: RollAxis(roll.rollAxis),
                         weight: Float(roll.weight ?? 1.0))
        } else if let aim = constraint.aim {
            self = .aim(source: aim.source,
                        axis: AimAxis(aim.aimAxis),
                        weight: Float(aim.weight ?? 1.0))
        } else if let rotation = constraint.rotation {
            self = .rotation(source: rotation.source,
                             weight: Float(rotation.weight ?? 1.0))
        } else {
            return nil
        }
    }

    package var source: Int {
        switch self {
        case .roll(let source, _, _),
             .aim(let source, _, _),
             .rotation(let source, _):
            return source
        }
    }
}

package enum VRMNodeConstraintRuntime {
    package static func evaluate(_ descriptor: VRMNodeConstraintDescriptor,
                                 sourceRestRotation: simd_quatf,
                                 sourceLocalRotation: simd_quatf,
                                 sourceWorldPosition: SIMD3<Float>,
                                 destinationRestRotation: simd_quatf,
                                 destinationParentWorldRotation: simd_quatf,
                                 destinationWorldPosition: SIMD3<Float>) -> simd_quatf {
        switch descriptor {
        case .roll(_, let axis, let weight):
            return evaluateRoll(axis: axis.vector,
                                weight: weight,
                                sourceRestRotation: sourceRestRotation,
                                sourceLocalRotation: sourceLocalRotation,
                                destinationRestRotation: destinationRestRotation)
        case .aim(_, let axis, let weight):
            return evaluateAim(axis: axis.vector,
                               weight: weight,
                               sourceWorldPosition: sourceWorldPosition,
                               destinationRestRotation: destinationRestRotation,
                               destinationParentWorldRotation: destinationParentWorldRotation,
                               destinationWorldPosition: destinationWorldPosition)
        case .rotation(_, let weight):
            return evaluateRotation(weight: weight,
                                    sourceRestRotation: sourceRestRotation,
                                    sourceLocalRotation: sourceLocalRotation,
                                    destinationRestRotation: destinationRestRotation)
        }
    }

    private static func evaluateRoll(axis: SIMD3<Float>,
                                     weight: Float,
                                     sourceRestRotation: simd_quatf,
                                     sourceLocalRotation: simd_quatf,
                                     destinationRestRotation: simd_quatf) -> simd_quatf {
        let deltaSource = simd_inverse(sourceRestRotation) * sourceLocalRotation
        let deltaSourceInParent = sourceRestRotation * deltaSource * simd_inverse(sourceRestRotation)
        let deltaSourceInDestination = simd_inverse(destinationRestRotation) * deltaSourceInParent * destinationRestRotation

        let toVector = deltaSourceInDestination * axis
        let fromToRotation = Self.fromToRotation(from: axis, to: toVector)
        let constrained = destinationRestRotation * simd_inverse(fromToRotation) * deltaSourceInDestination
        return slerpRest(destinationRestRotation, constrained, weight: weight)
    }

    private static func evaluateAim(axis: SIMD3<Float>,
                                    weight: Float,
                                    sourceWorldPosition: SIMD3<Float>,
                                    destinationRestRotation: simd_quatf,
                                    destinationParentWorldRotation: simd_quatf,
                                    destinationWorldPosition: SIMD3<Float>) -> simd_quatf {
        let fromVector = destinationParentWorldRotation * destinationRestRotation * axis
        let toVector = sourceWorldPosition - destinationWorldPosition
        let fromToRotation = Self.fromToRotation(from: fromVector, to: toVector)
        let constrained = simd_inverse(destinationParentWorldRotation) *
            fromToRotation *
            destinationParentWorldRotation *
            destinationRestRotation
        return slerpRest(destinationRestRotation, constrained, weight: weight)
    }

    private static func evaluateRotation(weight: Float,
                                         sourceRestRotation: simd_quatf,
                                         sourceLocalRotation: simd_quatf,
                                         destinationRestRotation: simd_quatf) -> simd_quatf {
        let deltaSource = simd_inverse(sourceRestRotation) * sourceLocalRotation
        return slerpRest(destinationRestRotation,
                         destinationRestRotation * deltaSource,
                         weight: weight)
    }

    private static func slerpRest(_ rest: simd_quatf,
                                  _ constrained: simd_quatf,
                                  weight: Float) -> simd_quatf {
        simd_slerp(normalized(rest), normalized(constrained), clamped(weight))
    }

    private static func fromToRotation(from rawFrom: SIMD3<Float>,
                                       to rawTo: SIMD3<Float>) -> simd_quatf {
        guard simd_length_squared(rawFrom) > Float.ulpOfOne,
              simd_length_squared(rawTo) > Float.ulpOfOne else {
            return quat_identity_float
        }

        let from = simd_normalize(rawFrom)
        let to = simd_normalize(rawTo)
        let dotValue = clamped(simd_dot(from, to), min: -1.0, max: 1.0)
        if dotValue > 1.0 - 0.000001 {
            return quat_identity_float
        }
        if dotValue < -1.0 + 0.000001 {
            let fallback = abs(from.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let axis = simd_normalize(simd_cross(from, fallback))
            return simd_quatf(angle: .pi, axis: axis)
        }

        let axis = simd_normalize(simd_cross(from, to))
        return simd_quatf(angle: acos(dotValue), axis: axis)
    }

    private static func normalized(_ quaternion: simd_quatf) -> simd_quatf {
        let lengthSquared = simd_dot(quaternion.vector, quaternion.vector)
        guard lengthSquared > Float.ulpOfOne else { return quat_identity_float }
        return simd_quatf(vector: quaternion.vector / sqrt(lengthSquared))
    }

    private static func clamped(_ value: Float,
                                min minimum: Float = 0.0,
                                max maximum: Float = 1.0) -> Float {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

private extension VRMNodeConstraintDescriptor.RollAxis {
    init(_ axis: GLTF.Node.NodeExtensions.NodeConstraint.Constraint.RollConstraint.RollAxis) {
        switch axis {
        case .x: self = .x
        case .y: self = .y
        case .z: self = .z
        }
    }

    var vector: SIMD3<Float> {
        switch self {
        case .x: return SIMD3<Float>(1, 0, 0)
        case .y: return SIMD3<Float>(0, 1, 0)
        case .z: return SIMD3<Float>(0, 0, 1)
        }
    }
}

private extension VRMNodeConstraintDescriptor.AimAxis {
    init(_ axis: GLTF.Node.NodeExtensions.NodeConstraint.Constraint.AimConstraint.AimAxis) {
        switch axis {
        case .positiveX: self = .positiveX
        case .negativeX: self = .negativeX
        case .positiveY: self = .positiveY
        case .negativeY: self = .negativeY
        case .positiveZ: self = .positiveZ
        case .negativeZ: self = .negativeZ
        }
    }

    var vector: SIMD3<Float> {
        switch self {
        case .positiveX: return SIMD3<Float>(1, 0, 0)
        case .negativeX: return SIMD3<Float>(-1, 0, 0)
        case .positiveY: return SIMD3<Float>(0, 1, 0)
        case .negativeY: return SIMD3<Float>(0, -1, 0)
        case .positiveZ: return SIMD3<Float>(0, 0, 1)
        case .negativeZ: return SIMD3<Float>(0, 0, -1)
        }
    }
}
