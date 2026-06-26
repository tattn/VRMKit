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
    @State private var realityKitViewModel = RealityKitContentViewModel()
    @State private var sceneKitViewModel = SceneKitContentViewModel()
    @State private var selectedRenderer: MacExampleRenderer = .realityKit
    @State private var selectedModel: MacExampleModel = .alicia
    @State private var selectedExpression: MacExampleExpression = .neutral
    
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
                        Text(expression.displayName).tag(expression)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding([.top, .horizontal])

            switch selectedRenderer {
            case .sceneKit:
                SceneKitRendererView(viewModel: sceneKitViewModel,
                                     selectedModel: selectedModel,
                                     selectedExpression: selectedExpression)
            case .realityKit:
                RealityKitRendererView(viewModel: realityKitViewModel,
                                       selectedModel: selectedModel,
                                       selectedExpression: selectedExpression)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

private struct RealityKitRendererView: View {
    let viewModel: RealityKitContentViewModel
    let selectedModel: MacExampleModel
    let selectedExpression: MacExampleExpression

    var body: some View {
        RealityView { content in
            content.add(viewModel.rootEntity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: selectedModel) {
            await viewModel.loadEntity(model: selectedModel, expression: selectedExpression)
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

private struct SceneKitRendererView: View {
    let viewModel: SceneKitContentViewModel
    let selectedModel: MacExampleModel
    let selectedExpression: MacExampleExpression

    var body: some View {
        SceneKitView(scene: viewModel.scene)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: selectedModel) {
                await viewModel.loadScene(model: selectedModel, expression: selectedExpression)
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
    let rootEntity = Entity()
    private(set) var errorMessage: String?
    private var vrmEntity: VRMEntity?
    private var time: TimeInterval = 0
    private var lastUpdateTime: Date?
    private var currentModel: MacExampleModel = .alicia
    private var currentExpression: MacExampleExpression = .neutral
    
    let updateTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    func loadEntity(model: MacExampleModel, expression: MacExampleExpression) async {
        do {
            errorMessage = nil
            if let vrmEntity {
                vrmEntity.entity.removeFromParent()
                self.vrmEntity = nil
            }

            let loader = try VRMEntityLoader(named: model.rawValue)
            let vrmEntity = try loader.loadEntity()
            
            vrmEntity.entity.transform.translation = SIMD3<Float>(0, -1, 0)
            vrmEntity.entity.transform.rotation = simd_quatf(angle: model.initialRotation, axis: SIMD3<Float>(0, 1, 0))
            rootEntity.addChild(vrmEntity.entity)
            
            // Adjust pose
            let neck = vrmEntity.humanoid.node(for: .neck)
            let leftArm: Entity?
            let rightArm: Entity?
            switch vrmEntity.vrm {
            case .v1:
                leftArm = vrmEntity.humanoid.node(for: .leftShoulder)
                rightArm = vrmEntity.humanoid.node(for: .rightShoulder)
            case .v0:
                leftArm = vrmEntity.humanoid.node(for: .leftUpperArm)
                rightArm = vrmEntity.humanoid.node(for: .rightUpperArm)
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
            vrmEntity.setBlendShape(value: 1.0, for: .preset(expression.preset))
            
            self.vrmEntity = vrmEntity
            self.currentModel = model
            self.currentExpression = expression
            self.lastUpdateTime = Date()
        } catch {
            errorMessage = error.localizedDescription
            print("VRM Load Error: \(error)")
        }
    }

    func setExpression(_ expression: MacExampleExpression) {
        guard expression != currentExpression else { return }
        vrmEntity?.setBlendShape(value: 0.0, for: .preset(currentExpression.preset))
        currentExpression = expression
        vrmEntity?.setBlendShape(value: 1.0, for: .preset(expression.preset))
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
        
        vrmEntity.entity.transform.rotation = simd_quatf(angle: currentModel.initialRotation + angle,
                                                         axis: SIMD3<Float>(0, 1, 0))
        vrmEntity.update(at: deltaTime)
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
        do {
            errorMessage = nil
            scene = nil
            vrmNode = nil
            time = 0

            let loader = try VRMSceneLoader(named: model.rawValue)
            let scene = try loader.loadScene()
            setUpCamera(in: scene)

            let node = scene.vrmNode
            node.eulerAngles = SCNVector3(0, CGFloat(model.sceneKitInitialRotation), 0)
            applyPose(to: node)
            node.setBlendShape(value: 1.0, for: .preset(expression.preset))

            self.scene = scene
            self.vrmNode = node
            self.currentModel = model
            self.currentExpression = expression
            self.lastUpdateTime = Date()
        } catch {
            errorMessage = error.localizedDescription
            print("VRM Load Error: \(error)")
        }
    }

    func setExpression(_ expression: MacExampleExpression) {
        guard expression != currentExpression else { return }
        vrmNode?.setBlendShape(value: 0.0, for: .preset(currentExpression.preset))
        currentExpression = expression
        vrmNode?.setBlendShape(value: 1.0, for: .preset(expression.preset))
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

        vrmNode.eulerAngles = SCNVector3(0, CGFloat(currentModel.sceneKitInitialRotation + angle), 0)
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
    }
}

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

enum MacExampleExpression: String, CaseIterable, Identifiable {
    case neutral, joy, angry, sorrow, fun

    var id: String { rawValue }

    var preset: BlendShapePreset {
        switch self {
        case .neutral: return .neutral
        case .joy: return .joy
        case .angry: return .angry
        case .sorrow: return .sorrow
        case .fun: return .fun
        }
    }

    var displayName: String {
        rawValue.capitalized
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
        case .alicia: return .pi
        case .vrm1: return 0
        }
    }

    var sceneKitInitialRotation: Float {
        switch self {
        case .alicia: return 0
        case .vrm1: return .pi
        }
    }
}

#Preview {
    ContentView()
}
