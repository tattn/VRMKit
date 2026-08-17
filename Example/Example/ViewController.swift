import UIKit
import SceneKit
import simd
internal import VRMSceneKit

class ViewController: UIViewController {

    @IBOutlet private weak var scnView: SCNView! {
        didSet {
            scnView.autoenablesDefaultLighting = true
            scnView.allowsCameraControl = true
            scnView.showsStatistics = true
            scnView.backgroundColor = UIColor.black
        }
    }

    private var vrmNode: VRMNode?
    private var expressionSegmentedControl: UISegmentedControl?
    private var currentModel: VRMExampleModel = .alicia
    private var currentExpression: ExampleExpression = .neutral

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadVRM(model: .alicia)
    }

    private func setupUI() {
        let items = VRMExampleModel.allCases.map { $0.displayName }
        let segmentedControl = UISegmentedControl(items: items)
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmentedControl)

        let expressionItems = ExampleExpression.allCases.map { $0.displayName(for: currentModel) }
        let expressionSegmentedControl = UISegmentedControl(items: expressionItems)
        expressionSegmentedControl.selectedSegmentIndex = 0
        expressionSegmentedControl.addTarget(self, action: #selector(expressionSegmentChanged(_:)), for: .valueChanged)
        expressionSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expressionSegmentedControl)
        self.expressionSegmentedControl = expressionSegmentedControl

        NSLayoutConstraint.activate([
            segmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            segmentedControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -50),

            expressionSegmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            expressionSegmentedControl.bottomAnchor.constraint(equalTo: segmentedControl.topAnchor, constant: -20)
        ])
    }

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        let model = VRMExampleModel.allCases[sender.selectedSegmentIndex]
        loadVRM(model: model)
    }

    @objc private func expressionSegmentChanged(_ sender: UISegmentedControl) {
        let expression = ExampleExpression.allCases[sender.selectedSegmentIndex]
        vrmNode?.setExampleExpression(currentExpression, value: 0.0)
        currentExpression = expression
        vrmNode?.setExampleExpression(currentExpression, value: 1.0)
    }

    private func loadVRM(model: VRMExampleModel) {
        do {
            currentModel = model
            updateExpressionLabels()
            let loader = try VRMSceneLoader(named: model.rawValue)
            let scene = try loader.loadScene()
            setupScene(scene)
            scnView.scene = scene
            scnView.delegate = self
            let node = scene.vrmNode
            self.vrmNode = node

            let rotationOffset = CGFloat(model.initialRotation)
            node.eulerAngles = SCNVector3(0, rotationOffset, 0)
            node.setExampleExpression(currentExpression, value: 1.0)

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

    private func updateExpressionLabels() {
        guard let expressionSegmentedControl else { return }
        let selectedIndex = expressionSegmentedControl.selectedSegmentIndex
        expressionSegmentedControl.removeAllSegments()
        for (index, expression) in ExampleExpression.allCases.enumerated() {
            expressionSegmentedControl.insertSegment(withTitle: expression.displayName(for: currentModel),
                                                     at: index,
                                                     animated: false)
        }
        expressionSegmentedControl.selectedSegmentIndex = selectedIndex >= 0 ? selectedIndex : 0
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
