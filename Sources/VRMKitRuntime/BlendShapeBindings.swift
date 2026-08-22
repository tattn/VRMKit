import simd
import VRMKit

/// Morph target binding shared by VRM 0.x BlendShape and VRM 1.0 Expression runtime clips.
package struct BlendShapeBinding<Mesh> {
    package let mesh: Mesh
    package let index: Int
    package let weight: Double

    package init(mesh: Mesh, index: Int, weight: Double) {
        self.mesh = mesh
        self.index = index
        self.weight = weight
    }
}

/// Runtime clip for VRM 0.x BlendShape groups.
package struct BlendShapeClip<Mesh> {
    package let name: String
    package let preset: BlendShapePreset
    package let values: [BlendShapeBinding<Mesh>]
    package let isBinary: Bool

    package var key: BlendShapeKey {
        return preset == .unknown ? .custom(name) : .preset(preset)
    }

    package init(name: String,
                 preset: BlendShapePreset,
                 values: [BlendShapeBinding<Mesh>],
                 isBinary: Bool) {
        self.name = name
        self.preset = preset
        self.values = values
        self.isBinary = isBinary
    }

    /// Clamps `value` to 0...1, rounding to the nearest of 0 and 1 for binary
    /// groups as VRM 0.x defines them.
    package func normalizedWeight(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return isBinary ? clamped.rounded() : clamped
    }
}

/// Runtime clip for VRM 1.0 Expressions.
package struct ExpressionClip<Mesh> {
    package let name: String
    package let preset: ExpressionPreset?
    package let values: [BlendShapeBinding<Mesh>]
    package let isBinary: Bool
    /// How this expression suppresses the blink / lookAt / mouth expressions
    /// while it is active (VRMC_vrm `overrideBlink` / `overrideLookAt` / `overrideMouth`).
    package let overrideBlink: ExpressionOverrideType
    package let overrideLookAt: ExpressionOverrideType
    package let overrideMouth: ExpressionOverrideType

    package var key: ExpressionKey {
        return preset.map(ExpressionKey.preset) ?? .custom(name)
    }

    package init(name: String,
                 preset: ExpressionPreset?,
                 values: [BlendShapeBinding<Mesh>],
                 isBinary: Bool,
                 overrideBlink: ExpressionOverrideType = .none,
                 overrideLookAt: ExpressionOverrideType = .none,
                 overrideMouth: ExpressionOverrideType = .none) {
        self.name = name
        self.preset = preset
        self.values = values
        self.isBinary = isBinary
        self.overrideBlink = overrideBlink
        self.overrideLookAt = overrideLookAt
        self.overrideMouth = overrideMouth
    }

    /// Clamps `value` to 0...1. VRM 1.0 binary expressions are 1 only when the
    /// weight is *greater than* 0.5, so exactly 0.5 stays 0.
    package func normalizedWeight(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return isBinary ? (clamped > 0.5 ? 1 : 0) : clamped
    }

    /// How this clip overrides `group`.
    package func overrideType(for group: ExpressionOverrideGroup) -> ExpressionOverrideType {
        switch group {
        case .blink: return overrideBlink
        case .lookAt: return overrideLookAt
        case .mouth: return overrideMouth
        }
    }
}

package typealias ExpressionOverrideType = VRM1.Expressions.Expression.ExpressionOverrideType

/// Accumulates every active expression's override of one group, following
/// VRMC_vrm: `block` zeroes the group outright, while simultaneous `blend`
/// overrides *add up* before being saturated, rather than composing
/// multiplicatively.
package struct ExpressionOverrideState {
    private var isBlocked = false
    private var blendWeight: Double = 0

    package init() {}

    package mutating func accumulate(_ type: ExpressionOverrideType, weight: Double) {
        guard weight > 0 else { return }
        switch type {
        case .none: break
        case .block: isBlocked = true
        case .blend: blendWeight += weight
        }
    }

    /// The share of the overridden group's weight that survives.
    package var factor: Double {
        isBlocked ? 0 : 1 - min(blendWeight, 1)
    }

    /// Whether the group receives any override effect at all.
    package var isSuppressing: Bool {
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
    package mutating func accumulate<Mesh>(_ clip: ExpressionClip<Mesh>,
                                           weight: Double,
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
    package var isSuppressingAnyGroup: Bool {
        blink.isSuppressing || lookAt.isSuppressing || mouth.isSuppressing
    }
}

/// Material value binding used by VRM 0.x BlendShape material values.
package struct MaterialValueBinding {
    package let materialName: String
    package let valueName: String
    package let targetValue: SIMD4<Float>
    package let baseValue: SIMD4<Float>

    package init(materialName: String,
                 valueName: String,
                 targetValue: SIMD4<Float>,
                 baseValue: SIMD4<Float>) {
        self.materialName = materialName
        self.valueName = valueName
        self.targetValue = targetValue
        self.baseValue = baseValue
    }
}
