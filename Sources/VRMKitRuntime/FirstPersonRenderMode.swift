import VRMKit

public enum FirstPersonRenderMode {
    case firstPerson
    case thirdPerson
}

package enum FirstPersonAnnotationType: Sendable, Equatable {
    case auto
    case both
    case thirdPersonOnly
    case firstPersonOnly

    package init(vrm1Type: VRM1.FirstPerson.FirstPersonType) {
        switch vrm1Type {
        case .auto: self = .auto
        case .both: self = .both
        case .thirdPersonOnly: self = .thirdPersonOnly
        case .firstPersonOnly: self = .firstPersonOnly
        }
    }

    package init?(vrm0Flag: String) {
        switch vrm0Flag.lowercased() {
        case "auto":
            self = .auto
        case "both":
            self = .both
        case "thirdpersononly":
            self = .thirdPersonOnly
        case "firstpersononly":
            self = .firstPersonOnly
        default:
            return nil
        }
    }

    /// Whether `mode` hides the mesh whole. An `auto` mesh normally keeps what
    /// the head does not draw, so `hidesAutoInFirstPerson` is only for the
    /// unskinned ones ``FirstPersonAutoMask`` cannot cut.
    package func isHidden(in mode: FirstPersonRenderMode, hidesAutoInFirstPerson: Bool) -> Bool {
        switch (self, mode) {
        case (.auto, .firstPerson):
            return hidesAutoInFirstPerson
        case (.firstPersonOnly, .thirdPerson),
             (.thirdPersonOnly, .firstPerson):
            return true
        default:
            return false
        }
    }
}
