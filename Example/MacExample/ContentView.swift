import SwiftUI
import RealityKit
internal import VRMRealityKit
internal import VRMKit

struct ContentView: View {
    @State private var selectedModel: MacExampleModel = .alicia
    @State private var selectedExpression: ExpressionKey = .preset(.neutral)
    @State private var expressions: [ExpressionInfo] = []
    @State private var isMToonEnabled = true

    var body: some View {
        VStack {
            HStack {
                Picker(selection: $selectedModel) {
                    ForEach(MacExampleModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                } label: {
                    Label("Model", systemImage: "figure.stand")
                }
                .pickerStyle(.segmented)

                Picker(selection: $selectedExpression) {
                    ForEach(expressions, id: \.key) { expression in
                        Text(expression.name).tag(expression.key)
                    }
                } label: {
                    Label("Expression", systemImage: "face.smiling")
                }
                .pickerStyle(.segmented)

                Toggle("MToon", isOn: $isMToonEnabled)
                    .toggleStyle(.button)
            }
            .labelStyle(.iconOnly)
            .padding([.top, .horizontal])

            RendererView(selectedModel: selectedModel,
                         selectedExpression: selectedExpression,
                         isMToonEnabled: isMToonEnabled,
                         expressions: $expressions)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

private struct RendererView: View {
    @State private var viewModel = ContentViewModel()
    let selectedModel: MacExampleModel
    let selectedExpression: ExpressionKey
    let isMToonEnabled: Bool
    /// Lifted to the picker above, which the loaded model names.
    @Binding var expressions: [ExpressionInfo]

    private var loadConfiguration: LoadConfiguration {
        LoadConfiguration(model: selectedModel, isMToonEnabled: isMToonEnabled)
    }

    var body: some View {
        RealityView { content in
            content.add(viewModel.makeRenderRootEntity())
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadConfiguration) {
            await viewModel.loadEntity(model: selectedModel,
                                       expression: selectedExpression,
                                       isMToonEnabled: isMToonEnabled)
            expressions = viewModel.availableExpressions
        }
        .onChange(of: selectedExpression) { _, expression in
            viewModel.setExpression(expression)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                viewModel.toggleVRMAPlayback()
            } label: {
                Label(viewModel.isVRMAPlaying ? "Stop VRMA" : "Play VRMA",
                      systemImage: viewModel.isVRMAPlaying ? "pause.fill" : "play.fill")
            }
            .labelStyle(.iconOnly)
            .padding()
        }
        .overlay(alignment: .bottomLeading) {
            if let errorMessage = viewModel.errorMessage {
                ErrorMessageView(message: errorMessage)
            }
        }
    }
}

private struct LoadConfiguration: Hashable {
    let model: MacExampleModel
    let isMToonEnabled: Bool
}

private struct ErrorMessageView: View {
    let message: String

    var body: some View {
        Text("Error: \(message)")
            .foregroundStyle(.red)
            .padding()
    }
}

@MainActor
@Observable
final class ContentViewModel {
    private var rootEntity = Entity()
    private(set) var errorMessage: String?
    private var vrmEntity: VRMEntity?
    private var cameraEntity: PerspectiveCamera?
    private var lightEntity: DirectionalLight?
    private var currentExpression: ExpressionKey = .preset(.neutral)
    private var orbitDistance: Float = 2
    private var orbitTarget = SIMD3<Float>(0, 0.8, 0)
    /// A three-quarter view from slightly above, which the iOS example shares.
    private let orbitYaw: Float = -35 * .pi / 180
    private let orbitPitch: Float = 21.5 * .pi / 180
    var isVRMAPlaying: Bool { vrmaController != nil }
    private var vrmaAnimation: VRMAnimation?
    private var vrmaController: GLTFAnimationPlaybackController?

    /// The example's emotions the loaded model offers, named the way it names them.
    var availableExpressions: [ExpressionInfo] {
        vrmEntity?.availableExpressions.exampleEmotions ?? []
    }

    func makeRenderRootEntity() -> Entity {
        let nextRootEntity = Entity()
        if let cameraEntity {
            nextRootEntity.addChild(cameraEntity)
        }
        if let lightEntity {
            nextRootEntity.addChild(lightEntity)
        }
        if let vrmEntity {
            nextRootEntity.addChild(vrmEntity)
        }
        rootEntity = nextRootEntity
        return nextRootEntity
    }

    func loadEntity(
        model: MacExampleModel,
        expression: ExpressionKey,
        isMToonEnabled: Bool
    ) async {
        await Task.yield()
        guard !Task.isCancelled else { return }

        do {
            errorMessage = nil

            let loader = try VRMEntityLoader(named: model.rawValue,
                                             shaders: isMToonEnabled ? GLTFEntityLoader.defaultShaders : [])
            let nextVRMEntity = try await loader.loadEntity()

            nextVRMEntity.transform.translation = SIMD3<Float>(0, -1, 0)
            nextVRMEntity.transform.rotation = simd_quatf(angle: model.initialRotation, axis: SIMD3<Float>(0, 1, 0))
            nextVRMEntity.setMToonLightDirection(MacExampleLighting.towardLight)
            setUpCamera()
            setUpLight()
            rootEntity.addChild(nextVRMEntity)
            normalizeScale(for: nextVRMEntity)
            updateCameraTransform()

            // The arms are left to the VRM animation started below.
            let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            if let neck = nextVRMEntity.humanoid.node(for: .neck) {
                neck.transform.rotation = neck.transform.rotation * neckRotation
            }
            apply(expression, replacing: nil, to: nextVRMEntity)

            let previousVRMEntity = self.vrmEntity
            self.vrmEntity = nextVRMEntity
            previousVRMEntity?.removeFromParent()
            vrmaController = nil
            startVRMAPlayback()
            self.currentExpression = expression
        } catch {
            errorMessage = error.localizedDescription
            print("VRM Load Error: \(error)")
        }
    }

    func setExpression(_ expression: ExpressionKey) {
        guard expression != currentExpression else { return }
        let previous = currentExpression
        currentExpression = expression
        guard let vrmEntity else { return }
        apply(expression, replacing: previous, to: vrmEntity)
    }

    /// The walk cycle plays from the moment a model loads, so this stops it
    /// and starts it again.
    func toggleVRMAPlayback() {
        if let vrmaController {
            vrmaController.stop()
            self.vrmaController = nil
        } else {
            startVRMAPlayback()
        }
    }

    private func startVRMAPlayback() {
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

    private func setUpLight() {
        if lightEntity == nil {
            let light = DirectionalLight()
            light.light.intensity = 1200
            rootEntity.addChild(light)
            lightEntity = light
        }
        // `towardLight` points at the light, so place the light there and aim it
        // at the origin.
        lightEntity?.look(at: .zero,
                          from: MacExampleLighting.towardLight,
                          relativeTo: nil)
    }

    private func setUpCamera() {
        if cameraEntity == nil {
            let camera = PerspectiveCamera()
            rootEntity.addChild(camera)
            cameraEntity = camera
        }
        updateCameraTransform()
    }

    private func normalizeScale(for entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let height = bounds.max.y - bounds.min.y
        guard height > 0.001 else { return }
        let targetHeight: Float = 2
        entity.transform.scale = SIMD3<Float>(repeating: targetHeight / height)
        updateOrbitTarget(for: entity)
    }

    private func updateOrbitTarget(for entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        orbitTarget = (bounds.min + bounds.max) * 0.5
        let extents = bounds.max - bounds.min
        let maxExtent = max(extents.x, max(extents.y, extents.z))
        // The camera has a 60° vertical field of view, so pulling back by the
        // model's largest extent frames the whole of it.
        orbitDistance = max(0.2, maxExtent)
    }

    private func updateCameraTransform() {
        guard let cameraEntity else { return }
        let yaw = simd_quatf(angle: orbitYaw, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: orbitPitch, axis: SIMD3<Float>(1, 0, 0))
        let position = orbitTarget + (yaw * pitch).act(SIMD3<Float>(0, 0, -orbitDistance))
        cameraEntity.look(at: orbitTarget, from: position, relativeTo: nil)
    }

    /// Both weights are sent together so the runtime re-applies its bindings once.
    private func apply(_ expression: ExpressionKey,
                       replacing previous: ExpressionKey?,
                       to vrmEntity: VRMEntity) {
        var weights: [ExpressionKey: CGFloat] = [expression: 1.0]
        if let previous, previous != expression {
            weights[previous] = 0.0
        }
        vrmEntity.setExpressions(weights)
    }
}

private enum MacExampleLighting {
    /// Direction from the model toward the light, as `setMToonLightDirection(_:)` expects.
    static let towardLight = simd_normalize(SIMD3<Float>(-0.35, -0.55, -0.75))
}

#Preview {
    ContentView()
}
