import UIKit

/// A renderer the example can host, so the navigation bar can own the choices
/// instead of each renderer repeating them.
@MainActor
protocol VRMRendererViewController: UIViewController {
    var model: VRMExampleModel { get set }
    /// Controls only this renderer has; the host installs them while it shows.
    var leadingBarButtonItems: [UIBarButtonItem] { get }
}

extension VRMRendererViewController {
    var leadingBarButtonItems: [UIBarButtonItem] { [] }
}

/// Both renderers stay alive once built: loading a VRM takes long enough that
/// rebuilding one on every switch would be felt.
final class RendererViewController: UIViewController {
    private enum Renderer: CaseIterable {
        case realityKit
        case sceneKit

        var displayName: String {
            switch self {
            case .realityKit: return "RealityKit"
            case .sceneKit: return "SceneKit"
            }
        }
    }

    private let rendererButton = UIBarButtonItem()
    private var renderers: [Renderer: any VRMRendererViewController] = [:]
    private var currentRenderer: (any VRMRendererViewController)?
    private var model: VRMExampleModel = .alicia

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let modelControl = UISegmentedControl(items: VRMExampleModel.allCases.map(\.displayName))
        modelControl.selectedSegmentIndex = 0
        modelControl.addTarget(self, action: #selector(modelChanged(_:)), for: .valueChanged)
        navigationItem.titleView = modelControl

        rendererButton.image = UIImage(systemName: "ellipsis")
        navigationItem.rightBarButtonItem = rendererButton

        show(.realityKit)
    }

    @objc private func modelChanged(_ sender: UISegmentedControl) {
        model = VRMExampleModel.allCases[sender.selectedSegmentIndex]
        currentRenderer?.model = model
    }

    private func show(_ renderer: Renderer) {
        updateRendererMenu(selecting: renderer)

        let next = controller(for: renderer)
        guard next !== currentRenderer else { return }

        if let currentRenderer {
            currentRenderer.willMove(toParent: nil)
            currentRenderer.view.removeFromSuperview()
            currentRenderer.removeFromParent()
        }

        addChild(next)
        // Before the view loads, so a renderer built while another model is
        // selected does not load its default first.
        next.model = model
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        currentRenderer = next
        navigationItem.leftBarButtonItems = next.leadingBarButtonItems
    }

    /// Rebuilt on every switch so the checkmark follows the selection.
    private func updateRendererMenu(selecting selected: Renderer) {
        rendererButton.menu = UIMenu(title: "Renderer", children: Renderer.allCases.map { renderer in
            UIAction(title: renderer.displayName,
                     state: renderer == selected ? .on : .off) { [weak self] _ in
                self?.show(renderer)
            }
        })
    }

    private func controller(for renderer: Renderer) -> any VRMRendererViewController {
        if let existing = renderers[renderer] { return existing }
        let controller: any VRMRendererViewController = switch renderer {
        case .realityKit: RealityKitViewController()
        case .sceneKit: ViewController()
        }
        renderers[renderer] = controller
        return controller
    }
}
