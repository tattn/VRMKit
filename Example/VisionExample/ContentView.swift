import SwiftUI
import RealityKit
import VRMRealityKit

struct MainView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: 20) {
            Text("VRM Example")
                .font(.largeTitle)

            Picker("Model", selection: $appModel.selectedModelName) {
                ForEach(AppModel.ModelName.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .disabled(appModel.immersiveSpaceState == .inTransition)

            Button {
                Task {
                    switch appModel.immersiveSpaceState {
                    case .closed:
                        appModel.immersiveSpaceState = .inTransition
                        let result = await openImmersiveSpace(id: appModel.immersiveSpaceID)
                        if case .error = result {
                            appModel.immersiveSpaceState = .closed
                        }
                    case .open:
                        appModel.immersiveSpaceState = .inTransition
                        await dismissImmersiveSpace()
                    case .inTransition:
                        break
                    }
                }
            } label: {
                Text(appModel.immersiveSpaceState == .open ? "Hide VRM" : "Show VRM")
            }
            .disabled(appModel.immersiveSpaceState == .inTransition)
        }
        .padding()
    }
}

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @State private var viewModel = ImmersiveViewModel()

    var body: some View {
        RealityView { content in
            content.add(viewModel.rootEntity)
        }
        .task {
            await viewModel.loadEntity(model: appModel.selectedModelName)
        }
        .onChange(of: appModel.selectedModelName) { _, newValue in
            Task {
                await viewModel.loadEntity(model: newValue)
            }
        }
        .onReceive(viewModel.updateTimer) { _ in
            viewModel.update()
        }
    }
}

@MainActor
@Observable
final class ImmersiveViewModel {
    let rootEntity = Entity()
    private(set) var errorMessage: String?
    private var vrmEntity: VRMEntity?
    private var time: TimeInterval = 0
    private var lastUpdateTime: Date?
    
    private var baseRotation: Float = 0
    
    let updateTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    func loadEntity(model: AppModel.ModelName) async {
        let modelName = model.rawValue
        
        // Clean up previous
        if let current = vrmEntity {
            current.entity.removeFromParent()
            vrmEntity = nil
        }
        
        // Alicia (VRM0) needs 180 degree rotation to face camera, VRM1 samples often don't
        baseRotation = model.initialRotation
        
        do {
            let loader = try VRMEntityLoader(named: modelName)
            let vrmEntity = try loader.loadEntity()
            
            vrmEntity.entity.transform.translation = SIMD3<Float>(0, 0, -1.5)
            vrmEntity.entity.transform.rotation = simd_quatf(angle: baseRotation, axis: SIMD3<Float>(0, 1, 0))
            rootEntity.addChild(vrmEntity.entity)

            // Adjust pose
            let neck = vrmEntity.humanoid.node(for: .neck)
            let leftShoulder = vrmEntity.humanoid.node(for: .leftShoulder) ?? vrmEntity.humanoid.node(for: .leftUpperArm)
            let rightShoulder = vrmEntity.humanoid.node(for: .rightShoulder) ?? vrmEntity.humanoid.node(for: .rightUpperArm)
            
            let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            let shoulderRotation = simd_quatf(angle: 40 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            if let neck {
                neck.transform.rotation = neck.transform.rotation * neckRotation
            }
            if let leftShoulder {
                leftShoulder.transform.rotation = leftShoulder.transform.rotation * shoulderRotation
            }
            if let rightShoulder {
                rightShoulder.transform.rotation = rightShoulder.transform.rotation * shoulderRotation
            }
            vrmEntity.setBlendShape(value: 1.0, for: .custom("><"))
            
            self.vrmEntity = vrmEntity
            self.lastUpdateTime = Date()
        } catch {
            errorMessage = error.localizedDescription
            print("VRM Load Error: \(error)")
        }
    }
    
    func update() {
        guard let vrmEntity else { return }
        
        let now = Date()
        let deltaTime = lastUpdateTime.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastUpdateTime = now
        
        time += deltaTime
        
        // An animation that sways left and right
        let cycle = time.truncatingRemainder(dividingBy: 1.0)
        let angle: Float
        if cycle < 0.5 {
            let progress = Float(cycle) / 0.5
            angle = -0.5 * progress
        } else {
            let progress = Float(cycle - 0.5) / 0.5
            angle = -0.5 + 0.5 * progress
        }
        
        vrmEntity.entity.transform.rotation = simd_quatf(angle: baseRotation + angle, axis: SIMD3<Float>(0, 1, 0))
        vrmEntity.update(at: deltaTime)
    }
}
