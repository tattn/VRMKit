#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
@testable import VRMRealityKit

#if os(iOS)
import ARKit
#endif

@Suite
@MainActor
struct ARIntegrationTests {

#if !os(visionOS)
    @Test
    func renderingModeNonARStillUsesCustomMaterial() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"))
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .nonAR)
        let material = try loader.material(withMaterialIndex: 0)
        _ = try #require(material as? CustomMaterial)
    }

    @Test
    func renderingModeARStillUsesCustomMaterialWithoutOutlineEntities() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"))
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .ar)
        let material = try loader.material(withMaterialIndex: 0)
        _ = try #require(material as? CustomMaterial)

        let vrmEntity = try loader.loadEntity()
        let outlineEntities = modelEntities(in: vrmEntity.entity).filter { modelEntity in
            guard let model = modelEntity.components[ModelComponent.self],
                  let outlineMaterial = model.materials.first as? CustomMaterial else {
                return false
            }
            return outlineMaterial.faceCulling == .front
        }
        #expect(outlineEntities.isEmpty)
    }

#if os(iOS) && !os(visionOS)
    @Test
    func loadMToonEntityInARViewWithoutCrash() async throws {
        guard #available(iOS 18.0, *) else { return }
        let arView = ARView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config)

        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"))
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .ar)
        let vrmEntity = try loader.loadEntity()

        var elapsedTime: TimeInterval = 0
        let subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { event in
            elapsedTime += event.deltaTime
            vrmEntity.update(at: elapsedTime)
        }

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(vrmEntity.entity)
        arView.scene.addAnchor(anchor)

        try await Task.sleep(nanoseconds: 500_000_000)

        subscription.cancel()
    }
#endif

    private func modelEntities(in root: Entity) -> [ModelEntity] {
        var results: [ModelEntity] = []
        if let modelEntity = root as? ModelEntity {
            results.append(modelEntity)
        }
        for child in root.children {
            results.append(contentsOf: modelEntities(in: child))
        }
        return results
    }
#endif
}
#endif
