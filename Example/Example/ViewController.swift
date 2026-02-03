import UIKit
import SceneKit
internal import VRMKit
internal import VRMSceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
enum VRMExampleModel: String, CaseIterable, Identifiable {
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
        case .alicia: return 0
        case .vrm1: return .pi
        }
    }
}

enum Expression: String, CaseIterable {
    case neutral, joy, angry, sorrow, fun
    
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
        return rawValue.capitalized
    }
}

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
    private var currentExpression: Expression = .neutral
    
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
        
        let expressionItems = Expression.allCases.map { $0.displayName }
        let expressionSegmentedControl = UISegmentedControl(items: expressionItems)
        expressionSegmentedControl.selectedSegmentIndex = 0
        expressionSegmentedControl.addTarget(self, action: #selector(expressionSegmentChanged(_:)), for: .valueChanged)
        expressionSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expressionSegmentedControl)
        
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
        let expression = Expression.allCases[sender.selectedSegmentIndex]
        vrmNode?.setBlendShape(value: 0.0, for: .preset(currentExpression.preset))
        currentExpression = expression
        vrmNode?.setBlendShape(value: 1.0, for: .preset(currentExpression.preset))
    }

    private func loadVRM(model: VRMExampleModel) {
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
            
            node.setBlendShape(value: 1.0, for: .preset(currentExpression.preset))
            
            node.humanoid.node(for: .neck)?.eulerAngles = SCNVector3(0, 0, 20 * CGFloat.pi / 180)
            node.humanoid.node(for: .leftShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
            node.humanoid.node(for: .rightShoulder)?.eulerAngles = SCNVector3(0, 0, 40 * CGFloat.pi / 180)
            
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
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension ViewController: SCNSceneRendererDelegate {
    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        (renderer.scene as! VRMScene).vrmNode.update(at: time)
    }
}
