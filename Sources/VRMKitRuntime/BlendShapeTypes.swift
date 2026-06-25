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

/// VRM expression preset.
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
    case happy
    case sad
    case relaxed
    case surprised
    case aa
    case ih
    case ou
    case ee
    case oh
    case blinkLeft
    case blinkRight

    public init(name: String) {
        switch name.replacingOccurrences(of: "_", with: "").lowercased() {
        case "neutral":
            self = .neutral
        case "a":
            self = .a
        case "i":
            self = .i
        case "u":
            self = .u
        case "e":
            self = .e
        case "o":
            self = .o
        case "blink":
            self = .blink
        case "joy":
            self = .joy
        case "angry":
            self = .angry
        case "sorrow":
            self = .sorrow
        case "fun":
            self = .fun
        case "lookup":
            self = .lookUp
        case "lookdown":
            self = .lookDown
        case "lookleft":
            self = .lookLeft
        case "lookright":
            self = .lookRight
        case "blinkl":
            self = .blinkL
        case "blinkr":
            self = .blinkR
        case "happy":
            self = .happy
        case "sad":
            self = .sad
        case "relaxed":
            self = .relaxed
        case "surprised":
            self = .surprised
        case "aa":
            self = .aa
        case "ih":
            self = .ih
        case "ou":
            self = .ou
        case "ee":
            self = .ee
        case "oh":
            self = .oh
        case "blinkleft":
            self = .blinkLeft
        case "blinkright":
            self = .blinkRight
        default:
            self = .unknown
        }
    }
}

package extension BlendShapePreset {
    var aliases: [BlendShapePreset] {
        switch self {
        case .joy: return [.happy]
        case .happy: return [.joy]
        case .sorrow: return [.sad]
        case .sad: return [.sorrow]
        case .fun: return [.relaxed]
        case .relaxed: return [.fun]
        case .a: return [.aa]
        case .aa: return [.a]
        case .i: return [.ih]
        case .ih: return [.i]
        case .u: return [.ou]
        case .ou: return [.u]
        case .e: return [.ee]
        case .ee: return [.e]
        case .o: return [.oh]
        case .oh: return [.o]
        case .blinkL: return [.blinkLeft]
        case .blinkLeft: return [.blinkL]
        case .blinkR: return [.blinkRight]
        case .blinkRight: return [.blinkR]
        default: return []
        }
    }
}

package extension BlendShapeKey {
    var aliases: [BlendShapeKey] {
        switch self {
        case .preset(let preset):
            return preset.aliases.map(BlendShapeKey.preset)
        case .custom:
            return []
        }
    }
}
