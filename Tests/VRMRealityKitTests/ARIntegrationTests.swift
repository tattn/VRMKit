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
    func outlineAndShadowOptionsAreIndependent() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()

        let noOutlineLoader = try VRMEntityLoader(withURL: url,
                                                  isOutlineEnabled: false,
                                                  isShadowCastingEnabled: true)
        let noOutlineEntity = try noOutlineLoader.loadEntity()
        #expect(noOutlineLoader.isOutlineEnabled == false)
        #expect(noOutlineLoader.isShadowCastingEnabled)
        #expect(noOutlineEntities(in: noOutlineEntity.entity))
        #expect(hasCustomMaterial(in: noOutlineEntity.entity))

        let noShadowLoader = try VRMEntityLoader(withURL: url,
                                                 isOutlineEnabled: true,
                                                 isShadowCastingEnabled: false)
        let noShadowEntity = try noShadowLoader.loadEntity()
        #expect(noShadowLoader.isOutlineEnabled)
        #expect(noShadowLoader.isShadowCastingEnabled == false)
        #expect(hasOutlineEntities(in: noShadowEntity.entity))
        assertShadowCastingDisabled(in: noShadowEntity.entity)
    }

    @Test
    func mtoonMaterialsPreserveAlphaModeWhenAROptionsAreDisabled() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url,
                                         isOutlineEnabled: false,
                                         isShadowCastingEnabled: false)
        let opaqueMaterial = try #require(loader.material(withMaterialIndex: 0) as? CustomMaterial)
        let blendMaterial = try #require(loader.material(withMaterialIndex: 4) as? CustomMaterial)

        #expect(isOpaque(opaqueMaterial.blending))
        #expect(isTransparent(blendMaterial.blending))
    }

    @Test
    func disabledMToonUsesFallbackMaterialWithAROptions() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url,
                                         isMToonEnabled: false,
                                         isOutlineEnabled: false,
                                         isShadowCastingEnabled: false)
        let vrmEntity = try loader.loadEntity()

        #expect(!hasCustomMaterial(in: vrmEntity.entity))
        assertShadowCastingDisabled(in: vrmEntity.entity)
    }

    @Test
    func defaultOptionsUseMToonAndOutlineEntities() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let url = try seedSanURL()
        let loader = try VRMEntityLoader(withURL: url)
        let vrmEntity = try loader.loadEntity()

        #expect(loader.isMToonEnabled)
        #expect(loader.isOutlineEnabled)
        #expect(loader.isShadowCastingEnabled)
        #expect(hasCustomMaterial(in: vrmEntity.entity))
        #expect(hasOutlineEntities(in: vrmEntity.entity))
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
        let loader = try VRMEntityLoader(withURL: url,
                                         isOutlineEnabled: false,
                                         isShadowCastingEnabled: false)
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

    private func hasCustomMaterial(in entity: Entity) -> Bool {
        allModelEntities(in: entity)
            .flatMap { $0.components[ModelComponent.self]?.materials ?? [] }
            .contains { $0 is CustomMaterial }
    }

    private func noOutlineEntities(in entity: Entity) -> Bool {
        if entity.name.hasSuffix("_outline") {
            return false
        }
        return entity.children.allSatisfy { noOutlineEntities(in: $0) }
    }

    private func hasOutlineEntities(in entity: Entity) -> Bool {
        !noOutlineEntities(in: entity)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func assertShadowCastingDisabled(in entity: Entity) {
        for modelEntity in allModelEntities(in: entity) {
            let dynamic = modelEntity.components[DynamicLightShadowComponent.self]
            #expect(dynamic?.castsShadow == false)

            let grounding = modelEntity.components[GroundingShadowComponent.self]
            #expect(grounding?.castsShadow == false)
            #expect(grounding?.receivesShadow == false)
        }
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

#if os(visionOS)
    @Test
    func visionOSUsesFallbackMaterialWhenMToonIsRequested() throws {
        guard #available(visionOS 2.0, *) else { return }
        let url = try #require(Bundle.module.url(forResource: "Seed-san", withExtension: "vrm"))
        let loader = try VRMEntityLoader(withURL: url)
        let material = try loader.material(withMaterialIndex: 0)

        #expect(loader.isMToonEnabled)
        #expect(loader.isOutlineEnabled)
        #expect(loader.isShadowCastingEnabled)
        #expect(material is UnlitMaterial || material is PhysicallyBasedMaterial)
    }
#endif
}
#endif
