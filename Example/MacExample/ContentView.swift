import SwiftUI
import SceneKit
import RealityKit
internal import VRMSceneKit
internal import VRMRealityKit
internal import Combine
internal import VRMKit

struct ContentView: View {
    @State private var selectedRenderer: MacExampleRenderer = .realityKit
    @State private var selectedModel: MacExampleModel = .alicia
    @State private var selectedExpression: ExpressionKey = .preset(.neutral)
    @State private var expressions: [ExpressionInfo] = []
    @State private var isMToonEnabled = true

    var body: some View {
        VStack {
            HStack {
                Picker(selection: $selectedRenderer) {
                    ForEach(MacExampleRenderer.allCases) { renderer in
                        Text(renderer.displayName).tag(renderer)
                    }
                } label: {
                    Label("Renderer", systemImage: "cube.transparent")
                }
                .pickerStyle(.menu)
                .fixedSize()

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
                    .disabled(selectedRenderer != .realityKit)
            }
            .labelStyle(.iconOnly)
            .padding([.top, .horizontal])

            // Only the selected renderer is mounted: keeping the other alive would
            // hold its scene graph, GPU resources and 60 Hz timer for nothing.
            switch selectedRenderer {
            case .sceneKit:
                SceneKitRendererView(selectedModel: selectedModel,
                                     selectedExpression: selectedExpression,
                                     expressions: $expressions)
            case .realityKit:
                RealityKitRendererView(selectedModel: selectedModel,
                                       selectedExpression: selectedExpression,
                                       isMToonEnabled: isMToonEnabled,
                                       expressions: $expressions)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

private struct RealityKitRendererView: View {
    @State private var viewModel = RealityKitContentViewModel()
    let selectedModel: MacExampleModel
    let selectedExpression: ExpressionKey
    let isMToonEnabled: Bool
    /// Lifted to the picker above, which the loaded model names.
    @Binding var expressions: [ExpressionInfo]

    private var loadConfiguration: RealityKitLoadConfiguration {
        RealityKitLoadConfiguration(model: selectedModel, isMToonEnabled: isMToonEnabled)
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

private struct RealityKitLoadConfiguration: Hashable {
    let model: MacExampleModel
    let isMToonEnabled: Bool
}

private struct SceneKitRendererView: View {
    @State private var viewModel = SceneKitContentViewModel()
    let selectedModel: MacExampleModel
    let selectedExpression: ExpressionKey
    /// Lifted to the picker above, which the loaded model names.
    @Binding var expressions: [ExpressionInfo]

    var body: some View {
        SceneKitView(scene: viewModel.scene)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: selectedModel) {
                await viewModel.loadScene(model: selectedModel, expression: selectedExpression)
                expressions = viewModel.availableExpressions
            }
            .onAppear {
                viewModel.resumeUpdates()
            }
            .onChange(of: selectedExpression) { _, expression in
                viewModel.setExpression(expression)
            }
            .onReceive(viewModel.updateTimer) { _ in
                viewModel.update()
            }
            .overlay(alignment: .bottomLeading) {
                if let errorMessage = viewModel.errorMessage {
                    ErrorMessageView(message: errorMessage)
                }
            }
    }
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
final class RealityKitContentViewModel {
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
        // Both renderers use a 60° vertical field of view, so pulling back by the
        // model's largest extent reproduces the SceneKit camera's framing.
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

private struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene?

    func makeNSView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.autoenablesDefaultLighting = true
        sceneView.allowsCameraControl = true
        sceneView.showsStatistics = true
        sceneView.backgroundColor = .black
        return sceneView
    }

    func updateNSView(_ sceneView: SCNView, context: Context) {
        sceneView.scene = scene
    }
}

@MainActor
@Observable
final class SceneKitContentViewModel {
    private(set) var scene: VRMScene?
    private(set) var errorMessage: String?
    private var vrmNode: VRMNode?
    private var time: TimeInterval = 0
    private var lastUpdateTime: Date?
    private var currentModel: MacExampleModel = .alicia
    private var currentExpression: ExpressionKey = .preset(.neutral)

    let updateTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    /// The example's emotions the loaded model offers, named the way it names them.
    var availableExpressions: [ExpressionInfo] {
        vrmNode?.availableExpressions.exampleEmotions ?? []
    }

    func loadScene(model: MacExampleModel, expression: ExpressionKey) async {
        if currentModel == model, let vrmNode {
            apply(expression, replacing: currentExpression, to: vrmNode)
            currentExpression = expression
            resumeUpdates()
            return
        }

        await Task.yield()
        guard !Task.isCancelled else { return }

        do {
            errorMessage = nil

            let loader = try VRMSceneLoader(named: model.rawValue)
            let scene = try loader.loadScene()
            setUpCamera(in: scene)

            let node = scene.vrmNode
            node.eulerAngles = SCNVector3(0, CGFloat(model.initialRotation), 0)
            applyPose(to: node)
            apply(expression, replacing: nil, to: node)

            self.scene = scene
            self.vrmNode = node
            self.currentModel = model
            self.currentExpression = expression
            self.time = 0
            resumeUpdates()
        } catch {
            errorMessage = error.localizedDescription
            print("VRM Load Error: \(error)")
        }
    }

    func setExpression(_ expression: ExpressionKey) {
        guard expression != currentExpression else { return }
        let previous = currentExpression
        currentExpression = expression
        guard let vrmNode else { return }
        apply(expression, replacing: previous, to: vrmNode)
    }

    func resumeUpdates() {
        lastUpdateTime = Date()
    }

    func update() {
        guard let vrmNode else { return }

        let now = Date()
        let deltaTime = lastUpdateTime.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastUpdateTime = now

        time += deltaTime

        let cycle = time.truncatingRemainder(dividingBy: 1.0)
        let angle: Float
        if cycle < 0.5 {
            let progress = Float(cycle) / 0.5
            angle = -0.5 * progress
        } else {
            let progress = Float(cycle - 0.5) / 0.5
            angle = -0.5 + 0.5 * progress
        }

        vrmNode.eulerAngles = SCNVector3(0, CGFloat(currentModel.initialRotation + angle), 0)
        vrmNode.update(at: time)
    }

    private func applyPose(to node: VRMNode) {
        node.humanoid.node(for: .neck)?.eulerAngles = SCNVector3(0, 0, 20 * CGFloat.pi / 180)

        let leftArm: SCNNode?
        let rightArm: SCNNode?
        switch node.vrm {
        case .v1:
            leftArm = node.humanoid.node(for: .leftShoulder)
            rightArm = node.humanoid.node(for: .rightShoulder)
        case .v0:
            leftArm = node.humanoid.node(for: .leftUpperArm)
            rightArm = node.humanoid.node(for: .rightUpperArm)
        }
        leftArm?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
        rightArm?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
    }

    private func setUpCamera(in scene: SCNScene) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0.8, -1.6)
        cameraNode.rotation = SCNVector4(0, 1, 0, Float.pi)
        scene.rootNode.addChildNode(cameraNode)

        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .directional
        lightNode.light?.intensity = 1200
        lightNode.simdPosition = MacExampleLighting.towardLight
        lightNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(lightNode)
    }

    /// Only the replaced expression needs clearing; this UI never has two active at once.
    private func apply(_ expression: ExpressionKey,
                       replacing previous: ExpressionKey?,
                       to vrmNode: VRMNode) {
        if let previous, previous != expression {
            vrmNode.setExpression(value: 0.0, for: previous)
        }
        vrmNode.setExpression(value: 1.0, for: expression)
    }
}

private enum MacExampleLighting {
    /// Direction from the model toward the light, as `setMToonLightDirection(_:)`
    /// expects. Both renderers place their directional light here.
    static let towardLight = simd_normalize(SIMD3<Float>(-0.35, -0.55, -0.75))
}

#Preview {
    ContentView()
}
