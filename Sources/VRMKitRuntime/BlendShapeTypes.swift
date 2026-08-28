import VRMKit

/// VRM 1.0 Expression Preset.
public enum ExpressionPreset: String, Sendable, CaseIterable {
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

public extension ExpressionPreset {
    /// The VRM 0.x `presetName` this expression is written as, or nil for a
    /// preset VRM 1.0 introduced.
    var vrm0PresetName: String? {
        Self.vrm0PresetNames[self]
    }

    /// The expression a VRM 0.x `presetName` stands for, whatever its casing.
    init?(vrm0PresetName: String) {
        guard let preset = Self.presetsByVRM0PresetName[vrm0PresetName.lowercased()] else { return nil }
        self = preset
    }

    private static let vrm0PresetNames: [ExpressionPreset: String] = [
        .neutral: "neutral",
        .aa: "a",
        .ih: "i",
        .ou: "u",
        .ee: "e",
        .oh: "o",
        .blink: "blink",
        .happy: "joy",
        .angry: "angry",
        .sad: "sorrow",
        .relaxed: "fun",
        .lookUp: "lookup",
        .lookDown: "lookdown",
        .lookLeft: "lookleft",
        .lookRight: "lookright",
        .blinkLeft: "blink_l",
        .blinkRight: "blink_r"
    ]

    private static let presetsByVRM0PresetName: [String: ExpressionPreset] =
        Dictionary(uniqueKeysWithValues: vrm0PresetNames.map { ($0.value, $0.key) })
}

/// VRM 1.0 Expression key.
///
/// Use this with `setExpression(value:for:)` / `expression(for:)` when working
/// with native VRM 1.0 expression presets or custom expressions.
public enum ExpressionKey: Hashable, Sendable {
    case preset(ExpressionPreset)
    case custom(String)

    /// The preset this is, or nil for a custom expression.
    public var preset: ExpressionPreset? {
        switch self {
        case .preset(let preset): return preset
        case .custom: return nil
        }
    }

    public var isPreset: Bool {
        preset != nil
    }
}

/// One expression a model offers: the key that drives it, and the name the model
/// itself gives it, which is `Joy` on a VRM 0.x model and `happy` on a 1.0 one.
public struct ExpressionInfo: Hashable, Sendable {
    /// The key to pass to `setExpression(value:for:)` / `expression(for:)`.
    public let key: ExpressionKey
    /// The VRM 1.0 expression name, or the VRM 0.x blend shape group name.
    public let name: String

    public init(key: ExpressionKey, name: String) {
        self.key = key
        self.name = name
    }

    /// The preset this is, or nil for a custom expression.
    public var preset: ExpressionPreset? { key.preset }
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
        preset?.overrideGroup
    }
}

package extension VRM0.BlendShapeMaster.BlendShapeGroup {
    /// The VRM 1.0 expression a VRM 0.x blend shape group is loaded as: the
    /// preset it declares, or failing that the one its name spells, which is how
    /// the models predating `presetName` name their presets.
    var expressionPreset: ExpressionPreset? {
        ExpressionPreset(vrm0PresetName: presetName) ?? ExpressionPreset(name: name)
    }
}
