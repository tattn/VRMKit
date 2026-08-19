//
//  ContentView.swift
//  MacExample
//
//  Created by tattn on 2026/01/26.
//  Copyright © 2026 tattn. All rights reserved.
//

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
    @State private var selectedExpression: MacExampleExpression = .neutral
    @State private var isMToonEnabled = true

    var body: some View {
        VStack {
            HStack {
                Picker("Renderer", selection: $selectedRenderer) {
                    ForEach(MacExampleRenderer.allCases) { renderer in
                        Text(renderer.displayName).tag(renderer)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Model", selection: $selectedModel) {
                    ForEach(MacExampleModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Expression", selection: $selectedExpression) {
                    ForEach(MacExampleExpression.allCases) { expression in
                        Text(expression.displayName(for: selectedModel)).tag(expression)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("MToon", isOn: $isMToonEnabled)
                    .toggleStyle(.switch)
                    .disabled(selectedRenderer != .realityKit)
            }
            .padding([.top, .horizontal])

            // Only the selected renderer is mounted: keeping the other alive
            // behind `opacity(0)` would hold on to its scene graph, GPU resources
            // and 60 Hz timer for a view nobody can see.
            switch selectedRenderer {
            case .sceneKit:
                SceneKitRendererView(selectedModel: selectedModel,
                                     selectedExpression: selectedExpression)
            case .realityKit:
                RealityKitRendererView(selectedModel: selectedModel,
                                       selectedExpression: selectedExpression,
                                       isMToonEnabled: isMToonEnabled)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

private struct RealityKitRendererView: View {
    @State private var viewModel = RealityKitContentViewModel()
    let selectedModel: MacExampleModel
    let selectedExpression: MacExampleExpression
    let isMToonEnabled: Bool

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

private struct RealityKitLoadConfiguration: Hashable {
    let model: MacExampleModel
    let isMToonEnabled: Bool
}

private struct SceneKitRendererView: View {
    @State private var viewModel = SceneKitContentViewModel()
    let selectedModel: MacExampleModel
    let selectedExpression: MacExampleExpression

    var body: some View {
        SceneKitView(scene: viewModel.scene)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: selectedModel) {
                await viewModel.loadScene(model: selectedModel, expression: selectedExpression)
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
    private var time: TimeInterval = 0
    private var lastUpdateTime: Date?
    private var currentModel: MacExampleModel = .alicia
    private var currentExpression: MacExampleExpression = .neutral
    private var orbitDistance: Float = 2
    private var orbitTarget = SIMD3<Float>(0, 0.8, 0)

    let updateTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

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
        expression: MacExampleExpression,
        isMToonEnabled: Bool
    ) async {
        await Task.yield()
        guard !Task.isCancelled else { return }

        do {
            errorMessage = nil

            let loader = try VRMEntityLoader(named: model.rawValue, isMToonEnabled: isMToonEnabled)
            let nextVRMEntity = try loader.loadEntity()

            nextVRMEntity.transform.translation = SIMD3<Float>(0, -1, 0)
            nextVRMEntity.transform.rotation = simd_quatf(angle: model.initialRotation, axis: SIMD3<Float>(0, 1, 0))
            nextVRMEntity.setMToonLightDirection(MacExampleLighting.towardLight)
            setUpCamera()
            setUpLight()
            rootEntity.addChild(nextVRMEntity)
            normalizeScale(for: nextVRMEntity)
            updateCameraTransform()

            let neck = nextVRMEntity.humanoid.node(for: .neck)
            let leftArm: Entity?
            let rightArm: Entity?
            switch nextVRMEntity.vrm {
            case .v1:
                leftArm = nextVRMEntity.humanoid.node(for: .leftShoulder)
                rightArm = nextVRMEntity.humanoid.node(for: .rightShoulder)
            case .v0:
                leftArm = nextVRMEntity.humanoid.node(for: .leftUpperArm)
                rightArm = nextVRMEntity.humanoid.node(for: .rightUpperArm)
            }

            let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            let armRotation = simd_quatf(angle: 40 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            if let neck {
                neck.transform.rotation = neck.transform.rotation * neckRotation
            }
            if let leftArm {
                leftArm.transform.rotation = leftArm.transform.rotation * armRotation
            }
            if let rightArm {
                rightArm.transform.rotation = rightArm.transform.rotation * armRotation
            }
            apply(expression, replacing: nil, to: nextVRMEntity)

            let previousVRMEntity = self.vrmEntity
            self.vrmEntity = nextVRMEntity
            previousVRMEntity?.removeFromParent()
            self.currentModel = model
            self.currentExpression = expression
            self.time = 0
            resumeUpdates()
        } catch {
            errorMessage = error.localizedDescription
            print("VRM Load Error: \(error)")
        }
    }

    func setExpression(_ expression: MacExampleExpression) {
        guard expression != currentExpression else { return }
        let previous = currentExpression
        currentExpression = expression
        guard let vrmEntity else { return }
        apply(expression, replacing: previous, to: vrmEntity)
    }

    func resumeUpdates() {
        lastUpdateTime = Date()
    }

    func update() {
        guard let vrmEntity else { return }

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

        vrmEntity.transform.rotation = simd_quatf(angle: currentModel.initialRotation + angle,
                                                  axis: SIMD3<Float>(0, 1, 0))
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
        // model's largest extent reproduces the framing the SceneKit camera gets
        // from sitting one body height away from the model.
        orbitDistance = max(0.2, maxExtent)
    }

    private func updateCameraTransform() {
        guard let cameraEntity else { return }
        let position = orbitTarget + SIMD3<Float>(0, 0, -orbitDistance)
        cameraEntity.look(at: orbitTarget, from: position, relativeTo: nil)
    }

    /// Both weights are sent together so the runtime re-applies its bindings once.
    private func apply(_ expression: MacExampleExpression,
                       replacing previous: MacExampleExpression?,
                       to vrmEntity: VRMEntity) {
        var weights: [MacExampleExpression: CGFloat] = [expression: 1.0]
        if let previous, previous != expression {
            weights[previous] = 0.0
        }
        vrmEntity.setExampleExpressions(weights)
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
    private var currentExpression: MacExampleExpression = .neutral

    let updateTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    func loadScene(model: MacExampleModel, expression: MacExampleExpression) async {
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

    func setExpression(_ expression: MacExampleExpression) {
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
    private func apply(_ expression: MacExampleExpression,
                       replacing previous: MacExampleExpression?,
                       to vrmNode: VRMNode) {
        if let previous, previous != expression {
            vrmNode.setExampleExpression(previous, value: 0.0)
        }
        vrmNode.setExampleExpression(expression, value: 1.0)
    }
}

private enum MacExampleLighting {
    /// Direction from the model toward the light, as `setMToonLightDirection(_:)`
    /// expects. Both renderers place their directional light here so that this
    /// example differs only in the renderer.
    static let towardLight = simd_normalize(SIMD3<Float>(-0.35, -0.55, -0.75))
}

#Preview {
    ContentView()
}
