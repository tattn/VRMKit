import VRMKit

/// VRM 1.0 Expression Preset.
public enum ExpressionPreset: String {
    case neutral
    case happy
    case angry
    case sad
    case relaxed
    case surprised
    case aa
    case ih
    case ou
    case ee
    case oh
    case blink
    case blinkLeft
    case blinkRight
    case lookUp
    case lookDown
    case lookLeft
    case lookRight

    public init?(name: String) {
        self.init(rawValue: name)
    }
}

/// VRM 1.0 Expression key.
///
/// Use this with `setExpression(value:for:)` / `expression(for:)` when working
/// with native VRM 1.0 expression presets or custom expressions.
public enum ExpressionKey: Hashable {
    case preset(ExpressionPreset)
    case custom(String)

    public var isPreset: Bool {
        switch self {
        case .preset: return true
        case .custom: return false
        }
    }
}

package extension ExpressionPreset {
    /// The group whose weights VRMC_vrm expression overrides suppress, or nil
    /// for presets no override applies to.
    var overrideGroup: ExpressionOverrideGroup? {
        switch self {
        case .blink, .blinkLeft, .blinkRight:
            return .blink
        case .lookUp, .lookDown, .lookLeft, .lookRight:
            return .lookAt
        case .aa, .ih, .ou, .ee, .oh:
            return .mouth
        case .neutral, .happy, .angry, .sad, .relaxed, .surprised:
            return nil
        }
    }
}

package extension ExpressionKey {
    var overrideGroup: ExpressionOverrideGroup? {
        switch self {
        case .preset(let preset): return preset.overrideGroup
        case .custom: return nil
        }
    }
}

package extension VRM0.BlendShapeMaster.BlendShapeGroup {
    /// The VRM 1.0 expression a VRM 0.x blend shape group is loaded as: the
    /// preset it declares, or failing that the one its name spells, which is how
    /// the models predating `presetName` name their presets.
    var expressionPreset: ExpressionPreset? {
        ExpressionPreset(vrm0Name: presetName) ?? ExpressionPreset(name: name)
    }
}

private extension ExpressionPreset {
    init?(vrm0Name: String) {
        switch vrm0Name.lowercased() {
        case "neutral": self = .neutral
        case "a": self = .aa
        case "i": self = .ih
        case "u": self = .ou
        case "e": self = .ee
        case "o": self = .oh
        case "blink": self = .blink
        case "joy": self = .happy
        case "angry": self = .angry
        case "sorrow": self = .sad
        case "fun": self = .relaxed
        case "lookup": self = .lookUp
        case "lookdown": self = .lookDown
        case "lookleft": self = .lookLeft
        case "lookright": self = .lookRight
        case "blink_l": self = .blinkLeft
        case "blink_r": self = .blinkRight
        default: return nil
        }
    }
}
