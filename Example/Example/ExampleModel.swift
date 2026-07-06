import CoreGraphics
import Foundation
internal import VRMKit
internal import VRMSceneKit

#if canImport(RealityKit)
internal import VRMRealityKit
#endif

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

enum ExampleExpression: String, CaseIterable {
    case neutral
    case joy
    case angry
    case sorrow
    case fun

    var blendShapePreset: BlendShapePreset {
        switch self {
        case .neutral: return .neutral
        case .joy: return .joy
        case .angry: return .angry
        case .sorrow: return .sorrow
        case .fun: return .fun
        }
    }

    var expressionPreset: ExpressionPreset {
        switch self {
        case .neutral: return .neutral
        case .joy: return .happy
        case .angry: return .angry
        case .sorrow: return .sad
        case .fun: return .relaxed
        }
    }

    func displayName(for model: VRMExampleModel) -> String {
        switch model {
        case .alicia:
            return rawValue.capitalized
        case .vrm1:
            switch self {
            case .neutral: return "Neutral"
            case .joy: return "Happy"
            case .angry: return "Angry"
            case .sorrow: return "Sad"
            case .fun: return "Relaxed"
            }
        }
    }
}

extension VRMNode {
    func setExampleExpression(_ expression: ExampleExpression, value: CGFloat) {
        switch vrm {
        case .v0:
            setBlendShape(value: value, for: .preset(expression.blendShapePreset))
        case .v1:
            setExpression(value: value, for: .preset(expression.expressionPreset))
        }
    }
}

#if canImport(RealityKit)
@available(iOS 18.0, *)
extension VRMEntity {
    func setExampleExpression(_ expression: ExampleExpression, value: CGFloat) {
        switch vrm {
        case .v0:
            setBlendShape(value: value, for: .preset(expression.blendShapePreset))
        case .v1:
            setExpression(value: value, for: .preset(expression.expressionPreset))
        }
    }
}
#endif
