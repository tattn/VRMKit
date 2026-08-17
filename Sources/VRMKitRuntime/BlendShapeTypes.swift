/// VRM 0.x BlendShape key.
///
/// VRM 1.0 expressions should use `ExpressionKey`; this type is kept for
/// VRM 0.x models and source compatibility with the older public API.
public enum BlendShapeKey: Hashable {
    case preset(BlendShapePreset)
    case custom(String)

    public var isPreset: Bool {
        switch self {
        case .preset: return true
        case .custom: return false
        }
    }
}

/// VRM 0.x Blend Shape Preset.
public enum BlendShapePreset: String {
    case unknown
    case neutral
    case a
    case i
    case u
    case e
    case o
    case blink
    case joy
    case angry
    case sorrow
    case fun
    case lookUp = "lookup"
    case lookDown = "lookdown"
    case lookLeft = "lookleft"
    case lookRight = "lookright"
    case blinkL = "blink_l"
    case blinkR = "blink_r"

    public init(name: String) {
        self = BlendShapePreset(rawValue: name.lowercased()) ?? .unknown
    }
}

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

package extension BlendShapePreset {
    /// Compatibility bridge from VRM 0.x blend shape presets to VRM 1.0 expressions.
    var expressionPreset: ExpressionPreset? {
        switch self {
        case .neutral: return .neutral
        case .a: return .aa
        case .i: return .ih
        case .u: return .ou
        case .e: return .ee
        case .o: return .oh
        case .blink: return .blink
        case .joy: return .happy
        case .angry: return .angry
        case .sorrow: return .sad
        case .fun: return .relaxed
        case .lookUp: return .lookUp
        case .lookDown: return .lookDown
        case .lookLeft: return .lookLeft
        case .lookRight: return .lookRight
        case .blinkL: return .blinkLeft
        case .blinkR: return .blinkRight
        case .unknown: return nil
        }
    }
}

package extension BlendShapeKey {
    /// Compatibility bridge for older `setBlendShape` calls on VRM 1.0 models.
    var expressionKey: ExpressionKey? {
        switch self {
        case .preset(let preset):
            return preset.expressionPreset.map(ExpressionKey.preset)
        case .custom(let name):
            if let preset = ExpressionPreset(name: name) {
                return .preset(preset)
            }
            return .custom(name)
        }
    }
}

package extension ExpressionPreset {
    /// Compatibility bridge from VRM 1.0 expression presets to legacy VRM 0.x names.
    var legacyBlendShapePreset: BlendShapePreset? {
        switch self {
        case .neutral: return .neutral
        case .aa: return .a
        case .ih: return .i
        case .ou: return .u
        case .ee: return .e
        case .oh: return .o
        case .blink: return .blink
        case .happy: return .joy
        case .angry: return .angry
        case .sad: return .sorrow
        case .relaxed: return .fun
        case .lookUp: return .lookUp
        case .lookDown: return .lookDown
        case .lookLeft: return .lookLeft
        case .lookRight: return .lookRight
        case .blinkLeft: return .blinkL
        case .blinkRight: return .blinkR
        case .surprised: return nil
        }
    }
}

package extension ExpressionKey {
    /// Compatibility bridge for code paths that still expose VRM 0.x blend shape keys.
    var legacyBlendShapeKey: BlendShapeKey? {
        switch self {
        case .preset(let preset):
            return preset.legacyBlendShapePreset.map(BlendShapeKey.preset)
        case .custom(let name):
            return .custom(name)
        }
    }
}
