import Foundation

/// Which VRM version a document is, which decides how everything the model says
/// about itself is spelled.
enum VRMSpecVersion {
    case v0
    case v1

    /// Nil for a glTF that is no VRM. A document carrying both extensions is
    /// read as 1.0, so reading and writing agree on which describes it.
    init?(rootExtensions: [String: Any]) {
        if rootExtensions[GLTFExtension.vrm1.rawValue] != nil {
            self = .v1
        } else if rootExtensions[GLTFExtension.vrm0.rawValue] != nil {
            self = .v0
        } else {
            return nil
        }
    }

    /// How the version is named in a message the caller reads.
    var displayName: String {
        switch self {
        case .v0: "VRM 0.x"
        case .v1: "VRM 1.0"
        }
    }

    /// The root extension describing the avatar: the meta and humanoid of both
    /// versions, and the spring bones of 0.x, which 1.0 keeps beside it in
    /// `VRMC_springBone`.
    var extensionName: String {
        switch self {
        case .v0: GLTFExtension.vrm0.rawValue
        case .v1: GLTFExtension.vrm1.rawValue
        }
    }
}
