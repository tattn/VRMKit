import simd
import VRMKit

package enum VRMNodeConstraintDescriptor {
    case roll(source: Int, axis: SIMD3<Float>, weight: Float)
    case aim(source: Int, axis: SIMD3<Float>, weight: Float)
    case rotation(source: Int, weight: Float)

    package init(_ constraint: GLTF.Node.NodeExtensions.NodeConstraint.Constraint) {
        let weight = Float(constraint.weight)
        switch constraint {
        case .roll(let roll):
            self = .roll(source: roll.source, axis: roll.rollAxis.vector, weight: weight)
        case .aim(let aim):
            self = .aim(source: aim.source, axis: aim.aimAxis.vector, weight: weight)
        case .rotation(let rotation):
            self = .rotation(source: rotation.source, weight: weight)
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

    /// The nodes this constraint reads, so that whatever constrains one of them
    /// is applied first.
    ///
    /// A roll or rotation constraint reads nothing but its source's local
    /// rotation. An aim constraint reads both ends in world space and the
    /// destination's parent world rotation, so everything above either end moves
    /// what it sees.
    package func dependencies(destination: Int, in hierarchy: GLTFNodeHierarchy) -> [Int] {
        switch self {
        case .roll, .rotation:
            return [source]
        case .aim:
            // The destination's ancestors rather than its lineage: the
            // destination itself is what this constraint poses.
            let destinationAncestors = hierarchy.parent(at: destination)
                .map { hierarchy.lineage(of: $0) } ?? []
            return hierarchy.lineage(of: source) + destinationAncestors
        }
    }
}

package enum VRMNodeConstraintRuntime {
    package static func evaluate(_ descriptor: VRMNodeConstraintDescriptor,
                                 sourceRestRotation: simd_quatf,
                                 sourceLocalRotation: @autoclosure () -> simd_quatf,
                                 sourceWorldPosition: @autoclosure () -> SIMD3<Float>,
                                 destinationRestRotation: simd_quatf,
                                 destinationParentWorldRotation: @autoclosure () -> simd_quatf,
                                 destinationWorldPosition: @autoclosure () -> SIMD3<Float>) -> simd_quatf {
        switch descriptor {
        case .roll(_, let axis, let weight):
            return evaluateRoll(axis: axis,
                                weight: weight,
                                sourceRestRotation: sourceRestRotation,
                                sourceLocalRotation: sourceLocalRotation(),
                                destinationRestRotation: destinationRestRotation)
        case .aim(_, let axis, let weight):
            return evaluateAim(axis: axis,
                               weight: weight,
                               sourceWorldPosition: sourceWorldPosition(),
                               destinationRestRotation: destinationRestRotation,
                               destinationParentWorldRotation: destinationParentWorldRotation(),
                               destinationWorldPosition: destinationWorldPosition())
        case .rotation(_, let weight):
            return evaluateRotation(weight: weight,
                                    sourceRestRotation: sourceRestRotation,
                                    sourceLocalRotation: sourceLocalRotation(),
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
        simd_slerp(rest.safelyNormalized, constrained.safelyNormalized, simd_clamp(weight, 0.0, 1.0))
    }

    private static func fromToRotation(from rawFrom: SIMD3<Float>,
                                       to rawTo: SIMD3<Float>) -> simd_quatf {
        guard simd_length_squared(rawFrom) > Float.ulpOfOne,
              simd_length_squared(rawTo) > Float.ulpOfOne else {
            return quat_identity_float
        }

        let from = simd_normalize(rawFrom)
        let to = simd_normalize(rawTo)
        let dotValue = simd_clamp(simd_dot(from, to), -1.0, 1.0)
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

}

/// Orders constraints so that every node a constraint reads is posed before it
/// runs, rejecting duplicate targets and dependency cycles independently of the
/// rendering backend that owns each binding. `dependencies` names the nodes one
/// binding reads, of which only the constrained ones order anything.
package func orderNodeConstraints<Binding>(
    _ bindings: [Binding],
    targetIndex: (Binding) -> Int,
    dependencies: (Binding) -> [Int]
) throws -> [Binding] {
    var byTargetIndex: [Int: Binding] = [:]
    for binding in bindings {
        let target = targetIndex(binding)
        guard byTargetIndex.updateValue(binding, forKey: target) == nil else {
            throw VRMError._dataInconsistent("Multiple constraints targeting the same node \(target)")
        }
    }

    var states: [Int: VisitState] = [:]
    var result: [Binding] = []
    func visit(_ binding: Binding) throws {
        let target = targetIndex(binding)
        switch states[target] {
        case .done: return
        case .visiting:
            throw VRMError._dataInconsistent(
                "VRMC_node_constraint circular dependency detected at node \(target)"
            )
        case nil: break
        }

        states[target] = .visiting
        for index in dependencies(binding) {
            if let dependency = byTargetIndex[index] {
                try visit(dependency)
            }
        }
        states[target] = .done
        result.append(binding)
    }

    for binding in bindings {
        try visit(binding)
    }
    return result
}

private enum VisitState {
    case visiting
    case done
}

private extension GLTF.Node.NodeExtensions.NodeConstraint.Constraint.RollConstraint.RollAxis {
    var vector: SIMD3<Float> {
        switch self {
        case .x: return SIMD3<Float>(1, 0, 0)
        case .y: return SIMD3<Float>(0, 1, 0)
        case .z: return SIMD3<Float>(0, 0, 1)
        }
    }
}

private extension GLTF.Node.NodeExtensions.NodeConstraint.Constraint.AimConstraint.AimAxis {
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
