import Foundation

public extension VRM {
    /// The glTF node each humanoid bone is mapped to, whichever version the
    /// model is.
    var boneNodes: [HumanoidBone: Int] {
        switch self {
        case .v0(let vrm0): vrm0.humanoid.boneNodes
        case .v1(let vrm1): vrm1.humanoid.boneNodes
        }
    }

    /// The glTF node a humanoid bone is mapped to, or nil when the model does
    /// not rig it.
    func nodeIndex(of bone: HumanoidBone) -> Int? { boneNodes[bone] }
}

public extension VRM0 {
    var boneNodes: [HumanoidBone: Int] { humanoid.boneNodes }

    func nodeIndex(of bone: HumanoidBone) -> Int? { boneNodes[bone] }
}

public extension VRM0.Humanoid {
    /// The node each bone the rig names is mapped to. VRM 0.x writes its rig
    /// as name / node pairs, so this is where it takes a VRM 1.0 rig's shape.
    var boneNodes: [HumanoidBone: Int] {
        humanBones.reduce(into: [:]) { nodes, humanBone in
            guard let bone = humanBone.humanoidBone else { return }
            nodes[bone] = humanBone.node
        }
    }
}

public extension VRM0.Humanoid.HumanBone {
    /// The bone this entry names, or nil for a name VRM does not define.
    var humanoidBone: HumanoidBone? { HumanoidBone(vrm0Name: bone) }
}

public extension VRM1 {
    var boneNodes: [HumanoidBone: Int] { humanoid.boneNodes }

    func nodeIndex(of bone: HumanoidBone) -> Int? { boneNodes[bone] }
}

public extension VRM1.Humanoid {
    var boneNodes: [HumanoidBone: Int] { humanBones.bones.mapValues(\.node) }
}

public extension HumanoidBone {
    /// The bone VRM 0.x writes under `name`, or nil for a name it does not
    /// define. Only the thumb is spelled differently from VRM 1.0.
    init?(vrm0Name name: String) {
        switch name {
        case "leftThumbProximal": self = .leftThumbMetacarpal
        case "leftThumbIntermediate": self = .leftThumbProximal
        case "rightThumbProximal": self = .rightThumbMetacarpal
        case "rightThumbIntermediate": self = .rightThumbProximal
        default:
            guard let bone = HumanoidBone(rawValue: name),
                  // A 1.0 thumb name is not one VRM 0.x has.
                  bone != .leftThumbMetacarpal, bone != .rightThumbMetacarpal else { return nil }
            self = bone
        }
    }

    /// What VRM 0.x calls this bone, the inverse of ``init(vrm0Name:)``.
    var vrm0Name: String {
        switch self {
        case .leftThumbMetacarpal: "leftThumbProximal"
        case .leftThumbProximal: "leftThumbIntermediate"
        case .rightThumbMetacarpal: "rightThumbProximal"
        case .rightThumbProximal: "rightThumbIntermediate"
        default: rawValue
        }
    }
}

