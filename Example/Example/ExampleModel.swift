enum VRMExampleModel: String, CaseIterable, Identifiable {
    case alicia = "AliciaSolid.vrm"
    case vrm1 = "VRM1_Constraint_Twist_Sample.vrm"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alicia: return "Alicia"
        case .vrm1: return "VRM 1.0"
        }
    }

    var initialRotation: Float {
        switch self {
        case .alicia: return 0
        case .vrm1: return .pi
        }
    }
}
