import UIKit
import RealityKit
import simd
internal import VRMKit
internal import VRMRealityKit

final class RealityKitViewController: UIViewController, UIGestureRecognizerDelegate {
    private var model: VRMExampleModel = .alicia {
        didSet {
            guard isViewLoaded, model != oldValue else { return }
            loadVRM()
        }
    }

    private var arView: ARView?
    private var loadedEntity: VRMEntity?
    private var loadedAnchor: AnchorEntity?
    private var cameraAnchor: AnchorEntity?
    private var cameraEntity: PerspectiveCamera?
    private var lightEntity: DirectionalLight?
    private let expressionControl = ExampleExpressionControl()
    private lazy var vrmaBarButtonItem = UIBarButtonItem(image: nil,
                                                         style: .plain,
                                                         target: self,
                                                         action: #selector(vrmaButtonTapped))
    private var vrmaAnimation: VRMAnimation?
    private var vrmaController: GLTFAnimationPlaybackController?
    /// A three-quarter view from slightly above reads better than a straight-on
    /// one for animations that move the model around.
    private var orbitYaw: Float = -35 * .pi / 180
    private var orbitPitch: Float = 21.5 * .pi / 180
    private var orbitDistance: Float = 2
    private var orbitTarget = SIMD3<Float>(0, 0.8, 0)
    private var isMToonEnabled = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setUpARView()
        setUpNavigationItem()
        setUpUI()
        loadVRM()
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

    private func setUpNavigationItem() {
        let modelControl = UISegmentedControl(items: VRMExampleModel.allCases.map(\.displayName))
        modelControl.selectedSegmentIndex = VRMExampleModel.allCases.firstIndex(of: model) ?? 0
        modelControl.addTarget(self, action: #selector(modelChanged(_:)), for: .valueChanged)
        navigationItem.titleView = modelControl
        navigationItem.leftBarButtonItem = vrmaBarButtonItem
    }

    @objc private func modelChanged(_ sender: UISegmentedControl) {
        model = VRMExampleModel.allCases[sender.selectedSegmentIndex]
    }

    private func setUpUI() {
        let expressionSegmentedControl = expressionControl.segmentedControl
        expressionSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expressionSegmentedControl)

        let mtoonButton = UIButton(type: .system)
        mtoonButton.changesSelectionAsPrimaryAction = true
        mtoonButton.isSelected = isMToonEnabled
        mtoonButton.configurationUpdateHandler = { button in
            var configuration: UIButton.Configuration = button.isSelected ? .filled() : .gray()
            configuration.title = "MToon"
            button.configuration = configuration
        }
        mtoonButton.addTarget(self, action: #selector(mtoonChanged(_:)), for: .primaryActionTriggered)

        mtoonButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mtoonButton)

        NSLayoutConstraint.activate([
            expressionSegmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            expressionSegmentedControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            mtoonButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mtoonButton.bottomAnchor.constraint(equalTo: expressionSegmentedControl.topAnchor, constant: -16)
        ])
    }

    @objc private func vrmaButtonTapped() {
        if let vrmaController {
            vrmaController.isPaused.toggle()
        } else {
            playVRMA()
        }
        updateVRMAButton()
    }

    private func playVRMA() {
        guard let loadedEntity else { return }
        do {
            vrmaController = try loadedEntity.playAnimation(loadedVRMAAnimation(), loops: true)
        } catch {
            print(error)
        }
    }

    private func loadedVRMAAnimation() throws -> VRMAnimation {
        if let vrmaAnimation { return vrmaAnimation }
        let animation = try VRMAnimation(named: "walk.vrma")
        vrmaAnimation = animation
        return animation
    }

    private func updateVRMAButton() {
        let isPlaying = vrmaController.map { !$0.isPaused } ?? false
        vrmaBarButtonItem.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
    }

    @objc private func mtoonChanged(_ sender: UIButton) {
        isMToonEnabled = sender.isSelected
        loadVRM()
    }

    private func loadVRM() {
        Task { await loadVRMAsync() }
    }

    private func loadVRMAsync() async {
        guard let arView = arView else { return }

        vrmaController = nil

        // Removing the anchor takes the whole model hierarchy out of the scene.
        if let loadedAnchor {
            arView.scene.removeAnchor(loadedAnchor)
            self.loadedAnchor = nil
        }
        loadedEntity = nil

        do {
            let loader = try VRMEntityLoader(named: model.rawValue,
                                             shaders: isMToonEnabled ? GLTFEntityLoader.defaultShaders : [])
            let vrmEntity = try await loader.loadEntity()
            vrmEntity.setMToonLightDirection(RealityKitExampleLighting.direction)

            let anchor = AnchorEntity(world: .zero)
            vrmEntity.transform.translation = SIMD3<Float>(0, -1.0, -1.5)
            vrmEntity.transform.rotation = simd_quatf(angle: model.initialRotation, axis: SIMD3<Float>(0, 1, 0))
            anchor.addChild(vrmEntity)
            arView.scene.addAnchor(anchor)
            setUpLight(in: arView)
            normalizeScale(for: vrmEntity)
            updateOrbitTarget(for: vrmEntity, adjustDistance: false)
            updateCameraTransform()

            // The arms are left to the VRM animation started below.
            let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            if let neck = vrmEntity.humanoid.node(for: .neck) {
                neck.transform.rotation = neck.transform.rotation * neckRotation
            }
            expressionControl.attach(to: vrmEntity)

            loadedEntity = vrmEntity
            loadedAnchor = anchor
            playVRMA()
        } catch {
            print(error)
        }
        updateVRMAButton()
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

    private func setUpLight(in arView: ARView) {
        if lightEntity != nil { return }
        let lightAnchor = AnchorEntity(world: .zero)
        let light = DirectionalLight()
        light.light.intensity = 1200
        // `direction` points at the light, so place the light there and aim it
        // at the origin.
        light.look(at: .zero,
                   from: RealityKitExampleLighting.direction,
                   relativeTo: nil)
        lightAnchor.addChild(light)
        arView.scene.addAnchor(lightAnchor)
        lightEntity = light
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
        let panSpeed = Float(0.002) * orbitDistance

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

private enum RealityKitExampleLighting {
    /// Direction from the model toward the light, as `setMToonLightDirection(_:)` expects.
    static let direction = simd_normalize(SIMD3<Float>(0, 0, -1))
}
