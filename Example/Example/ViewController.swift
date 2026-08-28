import UIKit
import SceneKit
import simd
internal import VRMSceneKit

class ViewController: UIViewController, VRMRendererViewController {
    var model: VRMExampleModel = .alicia {
        didSet {
            guard isViewLoaded, model != oldValue else { return }
            loadVRM()
        }
    }

    private let scnView = SCNView()
    private var vrmNode: VRMNode?
    private let expressionControl = ExampleExpressionControl()

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpSCNView()
        setupUI()
        loadVRM()
    }

    private func setUpSCNView() {
        scnView.autoenablesDefaultLighting = true
        scnView.allowsCameraControl = true
        scnView.showsStatistics = true
        scnView.backgroundColor = .black
        scnView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scnView)

        NSLayoutConstraint.activate([
            scnView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scnView.topAnchor.constraint(equalTo: view.topAnchor),
            scnView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupUI() {
        let expressionSegmentedControl = expressionControl.segmentedControl
        expressionSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expressionSegmentedControl)

        NSLayoutConstraint.activate([
            expressionSegmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            expressionSegmentedControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    private func loadVRM() {
        do {
            let loader = try VRMSceneLoader(named: model.rawValue)
            let scene = try loader.loadScene()
            setupScene(scene)
            scnView.scene = scene
            scnView.delegate = self
            let node = scene.vrmNode
            self.vrmNode = node

            let rotationOffset = CGFloat(model.initialRotation)
            node.eulerAngles = SCNVector3(0, rotationOffset, 0)
            expressionControl.attach(to: node)

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

            node.runAction(SCNAction.repeatForever(SCNAction.sequence([
                SCNAction.rotateBy(x: 0, y: -0.5, z: 0, duration: 0.5),
                SCNAction.rotateBy(x: 0, y: 0.5, z: 0, duration: 0.5),
            ])))
        } catch {
            print(error)
        }
    }

    private func setupScene(_ scene: SCNScene) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)

        cameraNode.position = SCNVector3(0, 0.8, -1.6)
        cameraNode.rotation = SCNVector4(0, 1, 0, Float.pi)

        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .directional
        lightNode.light?.intensity = 1200
        lightNode.simdPosition = -SceneKitExampleLighting.direction
        lightNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(lightNode)
    }
}

private enum SceneKitExampleLighting {
    static let direction = simd_normalize(SIMD3<Float>(0.35, 0.55, 0.75))
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension ViewController: SCNSceneRendererDelegate {
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        (renderer.scene as! VRMScene).vrmNode.update(at: time)
    }
}
