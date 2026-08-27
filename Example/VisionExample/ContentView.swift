import SwiftUI
import RealityKit
import VRMKit
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

            Toggle(isOn: $appModel.isVRMAPlaying) {
                Label("Play VRMA",
                      systemImage: appModel.isVRMAPlaying ? "pause.fill" : "play.fill")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .disabled(appModel.immersiveSpaceState != .open)

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
        .task(id: appModel.selectedModelName) {
            await viewModel.loadEntity(model: appModel.selectedModelName)
            viewModel.setVRMAPlaying(appModel.isVRMAPlaying)
        }
        .onChange(of: appModel.isVRMAPlaying) { _, isPlaying in
            viewModel.setVRMAPlaying(isPlaying)
        }
    }
}

@MainActor
@Observable
final class ImmersiveViewModel {
    let rootEntity = Entity()
    private(set) var errorMessage: String?
    private var vrmEntity: VRMEntity?
    private var vrmaAnimation: VRMAnimation?
    private var vrmaController: GLTFAnimationPlaybackController?

    func loadEntity(model: AppModel.ModelName) async {
        let modelName = model.rawValue

        if let current = vrmEntity {
            current.removeFromParent()
            vrmEntity = nil
            vrmaController = nil
        }
        
        do {
            // visionOS has no CustomMaterial, so MToon always falls back to
            // Unlit / PBR here.
            let loader = try VRMEntityLoader(named: modelName)
            let vrmEntity = try await loader.loadEntity()
            
            vrmEntity.transform.translation = SIMD3<Float>(0, 0, -1.5)
            // Alicia (VRM0) needs 180 degree rotation to face camera, VRM1 samples often don't
            vrmEntity.transform.rotation = simd_quatf(angle: model.initialRotation, axis: SIMD3<Float>(0, 1, 0))
            rootEntity.addChild(vrmEntity)

            // The arms are left to the VRM animation the view starts.
            let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            if let neck = vrmEntity.humanoid.node(for: .neck) {
                neck.transform.rotation = neck.transform.rotation * neckRotation
            }
            vrmEntity.setExpression(value: 1.0, for: .custom("><"))
            
            self.vrmEntity = vrmEntity
        } catch {
            errorMessage = error.localizedDescription
            print("VRM Load Error: \(error)")
        }
    }
    
    /// Starts or stops the bundled walk cycle, retargeted onto the model.
    func setVRMAPlaying(_ isPlaying: Bool) {
        guard isPlaying else {
            vrmaController?.stop()
            vrmaController = nil
            return
        }
        guard vrmaController == nil, let vrmEntity else { return }
        do {
            let animation = try loadedVRMAAnimation()
            vrmaController = try vrmEntity.playAnimation(animation, loops: true)
        } catch {
            errorMessage = error.localizedDescription
            print("VRMA Play Error: \(error)")
        }
    }

    private func loadedVRMAAnimation() throws -> VRMAnimation {
        if let vrmaAnimation { return vrmaAnimation }
        let animation = try VRMAnimation(named: "walk.vrma")
        vrmaAnimation = animation
        return animation
    }
}
