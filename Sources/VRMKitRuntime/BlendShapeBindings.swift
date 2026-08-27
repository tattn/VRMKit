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

/// What a binary clip makes of a weight of exactly 0.5, which is the one point
/// the two VRM versions disagree on.
package enum BinaryWeightRounding {
    /// VRM 0.x rounds a binary blend shape group to the nearest of 0 and 1.
    case nearest
    /// VRM 1.0 raises a binary expression only above 0.5.
    case aboveHalf
}

/// Runtime clip for one expression: a VRM 1.0 expression, or the VRM 0.x blend
/// shape group loaded as one.
package struct ExpressionClip<Mesh> {
    package let name: String
    package let preset: ExpressionPreset?
    package let values: [BlendShapeBinding<Mesh>]
    package let isBinary: Bool
    package let binaryRounding: BinaryWeightRounding
    /// How this expression suppresses the blink / lookAt / mouth expressions
    /// while it is active (VRMC_vrm `overrideBlink` / `overrideLookAt` / `overrideMouth`).
    /// A VRM 0.x group declares none of these.
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
                 binaryRounding: BinaryWeightRounding = .aboveHalf,
                 overrideBlink: ExpressionOverrideType = .none,
                 overrideLookAt: ExpressionOverrideType = .none,
                 overrideMouth: ExpressionOverrideType = .none) {
        self.name = name
        self.preset = preset
        self.values = values
        self.isBinary = isBinary
        self.binaryRounding = binaryRounding
        self.overrideBlink = overrideBlink
        self.overrideLookAt = overrideLookAt
        self.overrideMouth = overrideMouth
    }

    /// Clamps `value` to 0...1, resolving a binary clip to one of its ends.
    package func normalizedWeight(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        guard isBinary else { return clamped }
        switch binaryRounding {
        case .nearest: return clamped.rounded()
        case .aboveHalf: return clamped > 0.5 ? 1 : 0
        }
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

package extension Dictionary {
    /// The weights left once the active expressions have overridden one another,
    /// which is what a renderer applies. A binary expression is suppressed outright
    /// rather than scaled, having no partial state.
    func effectiveWeights<Mesh>(of weights: [ExpressionKey: Float]) -> [ExpressionKey: Float]
        where Key == ExpressionKey, Value == ExpressionClip<Mesh> {
        var states = ExpressionOverrideStates()
        for (key, weight) in weights {
            guard let clip = self[key] else { continue }
            states.accumulate(clip, weight: Double(weight), excluding: key.overrideGroup)
        }
        guard states.isSuppressingAnyGroup else { return weights }

        var effective: [ExpressionKey: Float] = [:]
        effective.reserveCapacity(weights.count)
        for (key, weight) in weights {
            guard let state = key.overrideGroup.map({ states[$0] }), state.isSuppressing else {
                effective[key] = weight
                continue
            }
            let overridden = self[key]?.isBinary == true ? 0 : weight * Float(state.factor)
            if overridden > 0 {
                effective[key] = overridden
            }
        }
        return effective
    }
}

package extension Dictionary {
    /// Resolves a custom key spelling a preset to the preset clip, while leaving
    /// ordinary custom expressions untouched.
    func canonicalKey<Mesh>(for key: ExpressionKey) -> ExpressionKey?
        where Key == ExpressionKey, Value == ExpressionClip<Mesh> {
        if self[key] != nil { return key }
        guard case .custom(let name) = key,
              let preset = ExpressionPreset(name: name),
              self[.preset(preset)] != nil else { return nil }
        return .preset(preset)
    }
}

/// Accumulates every active expression's override of one group, following
/// VRMC_vrm: `block` zeroes the group outright, while simultaneous `blend`
/// overrides add up before being saturated.
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
