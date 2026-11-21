import VRMKit

package typealias ExpressionOverrideType = VRM1.Expressions.Expression.ExpressionOverrideType

/// Accumulates every active expression's override of one group, following
/// VRMC_vrm: `block` zeroes the group outright, while simultaneous `blend`
/// overrides add up before being saturated.
package struct ExpressionOverrideState {
    private var isBlocked = false
    private var blendWeight: Float = 0

    package init() {}

    package mutating func accumulate(_ type: ExpressionOverrideType, weight: Float) {
        guard weight > 0 else { return }
        switch type {
        case .none: break
        case .block: isBlocked = true
        case .blend: blendWeight += weight
        }
    }

    /// The share of the overridden group's weight that survives.
    package var factor: Float {
        isBlocked ? 0 : 1 - min(blendWeight, 1)
    }

    /// Whether the group receives any override effect at all.
    var isSuppressing: Bool {
        factor < 1
    }
}

/// The expression groups that VRMC_vrm expression overrides can suppress.
package enum ExpressionOverrideGroup: CaseIterable {
    case blink
    case lookAt
    case mouth
}

/// The ``ExpressionOverrideState`` of every group. Stored inline rather than in
/// a dictionary: face tracking recomputes this on every expression update.
package struct ExpressionOverrideStates {
    private var blink = ExpressionOverrideState()
    private var lookAt = ExpressionOverrideState()
    private var mouth = ExpressionOverrideState()

    package init() {}

    package subscript(group: ExpressionOverrideGroup) -> ExpressionOverrideState {
        switch group {
        case .blink: return blink
        case .lookAt: return lookAt
        case .mouth: return mouth
        }
    }

    /// Accumulates `clip`'s overrides of every group but its own kind: a blink
    /// expression's `overrideBlink` is invalid.
    package mutating func accumulate(_ clip: VRMExpressionPlan.Clip,
                                     weight: Float,
                                     excluding ownGroup: ExpressionOverrideGroup?) {
        for group in ExpressionOverrideGroup.allCases where group != ownGroup {
            let type = clip.overrideType(for: group)
            switch group {
            case .blink: blink.accumulate(type, weight: weight)
            case .lookAt: lookAt.accumulate(type, weight: weight)
            case .mouth: mouth.accumulate(type, weight: weight)
            }
        }
    }

    /// Whether any group receives an override effect at all.
    var isSuppressingAnyGroup: Bool {
        blink.isSuppressing || lookAt.isSuppressing || mouth.isSuppressing
    }
}
