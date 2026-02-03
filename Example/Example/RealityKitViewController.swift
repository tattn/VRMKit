import Combine
import UIKit
import RealityKit
internal import VRMKit
internal import VRMRealityKit

@available(iOS 18.0, *)
final class RealityKitViewController: UIViewController, UIGestureRecognizerDelegate {
    private var arView: ARView?
    private var updateSubscription: Cancellable?
    private var loadedEntity: VRMEntity?
    private var cameraAnchor: AnchorEntity?
    private var cameraEntity: PerspectiveCamera?
    private var orbitYaw: Float = 0
    private var orbitPitch: Float = -0.1
    private var orbitDistance: Float = 2
    private var orbitTarget = SIMD3<Float>(0, 0.8, 0)
    private var currentExpression: Expression = .neutral

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "RealityKit"
        view.backgroundColor = .black
        setUpARView()
        setUpUI()
        loadVRM(model: .alicia)
    }

    private func setUpARView() {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.translatesAutoresizingMaskIntoConstraints = false
        arView.environment.background = .color(.black)
        view.addSubview(arView)

        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        self.arView = arView
        setUpCamera()
        setUpGestures()
    }

    private func setUpUI() {
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
        loadedEntity?.setBlendShape(value: 0.0, for: .preset(currentExpression.preset))
        currentExpression = expression
        loadedEntity?.setBlendShape(value: 1.0, for: .preset(currentExpression.preset))
    }

    private func loadVRM(model: VRMExampleModel) {
        guard let arView = arView else { return }

        if let loadedEntity = loadedEntity {
            loadedEntity.entity.removeFromParent()
            self.loadedEntity = nil
        }

        do {
            let loader = try VRMEntityLoader(named: model.rawValue)
            let vrmEntity = try loader.loadEntity()

            let anchor = AnchorEntity(world: .zero)
            vrmEntity.entity.transform.translation = SIMD3<Float>(0, -1.0, -1.5)
            anchor.addChild(vrmEntity.entity)
            arView.scene.addAnchor(anchor)
            normalizeScale(for: vrmEntity.entity)
            updateOrbitTarget(for: vrmEntity.entity, adjustDistance: false)
            updateCameraTransform()
            
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
            vrmEntity.setBlendShape(value: 1.0, for: .preset(currentExpression.preset))
            
            loadedEntity = vrmEntity
            
            let rotationOffset = model.initialRotation

            var time: TimeInterval = 0
            updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                guard let loadedEntity = self?.loadedEntity else { return }
                
                time += event.deltaTime
                
                let cycle = time.truncatingRemainder(dividingBy: 1.0)
                let angle: Float
                if cycle < 0.5 {
                    let progress = Float(cycle) / 0.5
                    angle = -0.5 * progress
                } else {
                    let progress = Float(cycle - 0.5) / 0.5
                    angle = -0.5 + 0.5 * progress
                }
                
                loadedEntity.entity.transform.rotation = simd_quatf(angle: rotationOffset + angle, axis: SIMD3<Float>(0, 1, 0))
                
                loadedEntity.update(at: event.deltaTime)
            }
        } catch {
            print(error)
        }
    }

    private func setUpCamera() {
        guard let arView = arView else { return }
        let cameraAnchor = AnchorEntity(world: .zero)
        let cameraEntity = PerspectiveCamera()
        cameraAnchor.addChild(cameraEntity)
        arView.scene.addAnchor(cameraAnchor)
        self.cameraAnchor = cameraAnchor
        self.cameraEntity = cameraEntity
        updateCameraTransform()
    }

    private func setUpGestures() {
        guard let arView = arView else { return }

        let orbitPan = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan(_:)))
        orbitPan.minimumNumberOfTouches = 1
        orbitPan.maximumNumberOfTouches = 1
        orbitPan.delegate = self
        arView.addGestureRecognizer(orbitPan)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        arView.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        arView.addGestureRecognizer(pinch)
    }

    private func updateOrbitTarget(for entity: Entity, adjustDistance: Bool = true) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let center = (bounds.min + bounds.max) * 0.5
        let extents = bounds.max - bounds.min
        let maxExtent = max(extents.x, max(extents.y, extents.z))
        orbitTarget = center
        if adjustDistance {
            orbitDistance = max(0.2, maxExtent * 3.0)
        }
        updateCameraTransform()
    }

    private func normalizeScale(for entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let height = bounds.max.y - bounds.min.y
        guard height > 0.001 else { return }
        let targetHeight: Float = 2
        let scale = targetHeight / height
        entity.transform.scale = SIMD3<Float>(repeating: scale)
    }

    private func updateCameraTransform() {
        guard let cameraEntity = cameraEntity else { return }
        orbitPitch = max(-1.4, min(1.4, orbitPitch))
        orbitDistance = max(0.05, orbitDistance)

        let yaw = simd_quatf(angle: orbitYaw, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: orbitPitch, axis: SIMD3<Float>(1, 0, 0))
        let rotation = yaw * pitch
        let offset = rotation.act(SIMD3<Float>(0, 0, -orbitDistance))
        let position = orbitTarget + offset
        cameraEntity.look(at: orbitTarget, from: position, relativeTo: nil)
    }

    @objc private func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
        guard let arView = arView else { return }
        let translation = gesture.translation(in: arView)
        let sensitivity: Float = 0.005
        orbitYaw -= Float(translation.x) * sensitivity
        orbitPitch -= Float(translation.y) * sensitivity
        gesture.setTranslation(.zero, in: arView)
        updateCameraTransform()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let arView = arView, let cameraEntity = cameraEntity else { return }
        let translation = gesture.translation(in: arView)
        let panSpeed: Float = 0.002 * orbitDistance

        let transform = cameraEntity.transform.matrix
        let right = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)

        orbitTarget += right * Float(translation.x) * panSpeed
        orbitTarget -= up * Float(translation.y) * panSpeed

        gesture.setTranslation(.zero, in: arView)
        updateCameraTransform()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let scale = Float(gesture.scale)
        if scale > 0 {
            orbitDistance = orbitDistance / scale
        }
        gesture.scale = 1.0
        updateCameraTransform()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
