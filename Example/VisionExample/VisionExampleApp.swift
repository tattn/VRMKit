import SwiftUI

@main
struct VisionExampleApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

@Observable
@MainActor
final class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    var immersiveSpaceState: ImmersiveSpaceState = .closed

    enum ImmersiveSpaceState {
        case closed, inTransition, open
    }
    enum ModelName: String, CaseIterable, Identifiable {
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
            case .alicia: return .pi
            case .vrm1: return 0
            }
        }
    }
    
    var selectedModelName: ModelName = .alicia
}
