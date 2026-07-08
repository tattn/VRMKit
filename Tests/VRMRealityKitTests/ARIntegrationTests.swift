#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
@testable import VRMRealityKit

#if os(iOS)
import ARKit
#endif

@Suite("AR MToon Integration")
@MainActor
struct ARIntegrationTests {

#if !os(visionOS)
    @Test
    func arModeMaterialHasNoGeometryModifier() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .ar)
        let vrmEntity = try loader.loadEntity()

        let customMaterials = allModelEntities(in: vrmEntity.entity)
            .flatMap { $0.components[ModelComponent.self]?.materials ?? [] }
            .compactMap { $0 as? CustomMaterial }

        #expect(!customMaterials.isEmpty)
        #expect(noOutlineEntities(in: vrmEntity.entity))
    }

    @Test
    func arModePreservesMToonBlendAlphaMode() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .ar)
        let opaqueMaterial = try #require(loader.material(withMaterialIndex: 0) as? CustomMaterial)
        let blendMaterial = try #require(loader.material(withMaterialIndex: 4) as? CustomMaterial)

        #expect(isOpaque(opaqueMaterial.blending))
        #expect(isTransparent(blendMaterial.blending))
    }

    @Test
    func arModeEntitiesHaveShadowCastingDisabled() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .ar)
        let vrmEntity = try loader.loadEntity()

        for modelEntity in allModelEntities(in: vrmEntity.entity) {
            let dynamic = modelEntity.components[DynamicLightShadowComponent.self]
            #expect(dynamic?.castsShadow == false)

            let grounding = modelEntity.components[GroundingShadowComponent.self]
            #expect(grounding?.castsShadow == false)
            #expect(grounding?.receivesShadow == false)
        }
    }

    @Test
    func nonARModeStillUsesOutlineEntities() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .nonAR)
        let vrmEntity = try loader.loadEntity()

        let outlineEntities = allModelEntities(in: vrmEntity.entity).filter { modelEntity in
            guard let model = modelEntity.components[ModelComponent.self],
                  let outlineMaterial = model.materials.first as? CustomMaterial else {
                return false
            }
            return outlineMaterial.faceCulling == .front
        }
        #expect(!outlineEntities.isEmpty)
    }

    @Test
    func arModeWithMToonDisabledUsesUnlitNotCustomMaterial() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url, isMToonEnabled: false, renderingMode: .ar)
        let vrmEntity = try loader.loadEntity()

        let hasCustom = allModelEntities(in: vrmEntity.entity)
            .flatMap { $0.components[ModelComponent.self]?.materials ?? [] }
            .contains { $0 is CustomMaterial }
        #expect(!hasCustom)
    }

    @Test
    func renderingModeNonARStillUsesCustomMaterial() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .nonAR)
        let material = try loader.material(withMaterialIndex: 0)
        _ = try #require(material as? CustomMaterial)
    }

#if os(iOS) && !os(visionOS)
    @Test
    func loadMToonEntityInARViewSurvivesRenderFrames() async throws {
        guard #available(iOS 18.0, *) else { return }
        let arView = ARView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        arView.renderOptions.insert(.disableGroundingShadows)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config)

        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url, renderingMode: .ar)
        let vrmEntity = try loader.loadEntity()

        var elapsed: TimeInterval = 0
        let subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { event in
            elapsed += event.deltaTime
            vrmEntity.setMToonLightDirection(SIMD3<Float>(0, 0, -1))
            vrmEntity.update(at: elapsed)
        }

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(vrmEntity.entity)
        arView.scene.addAnchor(anchor)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        subscription.cancel()
    }
#endif

    private func seedSanURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"))
    }

    private func allModelEntities(in entity: Entity) -> [ModelEntity] {
        var result: [ModelEntity] = []
        if let model = entity as? ModelEntity {
            result.append(model)
        }
        for child in entity.children {
            result.append(contentsOf: allModelEntities(in: child))
        }
        return result
    }

    private func noOutlineEntities(in entity: Entity) -> Bool {
        if entity.name.hasSuffix("_outline") {
            return false
        }
        return entity.children.allSatisfy { noOutlineEntities(in: $0) }
    }

    private func isOpaque(_ blending: CustomMaterial.Blending) -> Bool {
        if case .opaque = blending {
            return true
        }
        return false
    }

    private func isTransparent(_ blending: CustomMaterial.Blending) -> Bool {
        if case .transparent = blending {
            return true
        }
        return false
    }
#endif
}
#endif
