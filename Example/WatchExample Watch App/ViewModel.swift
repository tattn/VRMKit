import Foundation
internal import VRMSceneKit
import SceneKit

@available(*, deprecated, message: "Deprecated. But watchOS can't use RealityKit...")
final class Renderer: NSObject, SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        (renderer.scene as! VRMScene).vrmNode.update(at: time)
    }
}

@available(*, deprecated, message: "Deprecated. But watchOS can't use RealityKit...")
final class ViewModel: ObservableObject {
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

        var initialRotation: CGFloat {
            switch self {
            case .alicia: return 0
            case .vrm1: return .pi
            }
        }
    }

    @Published var selectedModelName: ModelName = .alicia {
        didSet {
            // Reload when selection changes
            loadModel(model: selectedModelName)
        }
    }
    @Published private(set) var scene: VRMScene?
    let renderer = Renderer()

    func loadModelIfNeeded() {
        guard scene == nil else { return }
        loadModel(model: selectedModelName)
    }

    private func loadModel(model: ModelName) {
        do {
            let loader = try VRMSceneLoader(named: model.rawValue)
            let scene = try loader.loadScene()
            setupScene(scene)

            let node = scene.vrmNode
            let rotationOffset = model.initialRotation
            node.eulerAngles = SCNVector3(0, rotationOffset, 0)

            node.humanoid.node(for: .leftShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
            node.humanoid.node(for: .rightShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / -180)

            node.runAction(.repeatForever(.sequence([
                .wait(duration: 3.0),
                .customAction(duration: 0.5) { node, time in
                    let vrmNode = node as! VRMNode
                    return vrmNode.setBlendShape(value: time / 0.5, for: .preset(.blink))
                },
                .customAction(duration: 0.5) { node, time in
                    let vrmNode = node as! VRMNode
                    return vrmNode.setBlendShape(value: 1.0 - time / 0.5, for: .preset(.blink))
                },
            ])))
        } catch {
            print(error)
        }
    }

    private func setupScene(_ scene: VRMScene) {
        self.scene = scene

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        scene.rootNode.addChildNode(cameraNode)

        cameraNode.position = SCNVector3(0, 1.4, -0.4)
        cameraNode.rotation = SCNVector4(0, 1, 0, Float.pi)
    }
}
