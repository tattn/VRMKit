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

/// VRM 0.x Blend Shape Preset
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

    package init(name: String) {
        self = BlendShapePreset(rawValue: name.lowercased()) ?? .unknown
    }
}
