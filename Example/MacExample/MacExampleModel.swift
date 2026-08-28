internal import VRMSceneKit

enum MacExampleRenderer: String, CaseIterable, Identifiable {
    case sceneKit
    case realityKit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sceneKit: return "SceneKit"
        case .realityKit: return "RealityKit"
        }
    }
}

enum MacExampleModel: String, CaseIterable, Identifiable {
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

extension [ExpressionInfo] {
    /// The emotions the example shows, in the order it shows them, dropping the
    /// ones the model states no expression for.
    var exampleEmotions: [ExpressionInfo] {
        let presets: [ExpressionPreset] = [.neutral, .happy, .angry, .sad, .relaxed]
        return presets.compactMap { preset in first { $0.preset == preset } }
    }
}
