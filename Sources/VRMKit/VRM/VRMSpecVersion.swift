import Foundation

/// Which VRM version a document is, which decides how everything the model says
/// about itself is spelled.
enum VRMSpecVersion {
    case v0
    case v1

    /// Which version the root extensions say the document is. One carrying both,
    /// or neither, is refused rather than read as whichever comes first.
    init(rootExtensions: [String: some Any]) throws {
        switch (rootExtensions[GLTFExtension.vrm0.rawValue], rootExtensions[GLTFExtension.vrm1.rawValue]) {
        case (_?, nil): self = .v0
        case (nil, _?): self = .v1
        case (_?, _?):
            throw VRMError._dataInconsistent(
                "the document carries both \(GLTFExtension.vrm0.rawValue) and \(GLTFExtension.vrm1.rawValue), "
                + "so which version describes it is not for this to guess"
            )
        case (nil, nil):
            throw VRMError._notSupported("the document carries no VRM extension")
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
