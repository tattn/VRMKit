#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What a load returns: the entity for the scene, the runtime that drives it,
/// and the picture the model states for itself.
@Suite
@MainActor
struct VRMEntityTests {
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testLoadEntityReturnsTheEntityItsVRMAndItsThumbnail(asset: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: asset.data)
        let entity = try await loader.loadEntity()

        #expect(entity.document === entity.vrm.document)
        #expect(!entity.availableExpressions.isEmpty)
        #expect(entity.humanoid.node(for: .head) != nil)
        #expect(try loader.loadThumbnail().width > 0)
    }

    /// A VRM 1.0 model states its presets under the names 1.0 spells them with,
    /// unlike a 0.x one, which names its groups whatever it likes.
    @Test
    func testAvailableExpressionsCarryTheNamesTheModelStates() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        let expressions = entity.availableExpressions
        #expect(expressions.contains(ExpressionInfo(key: .preset(.happy), name: "happy")))
        for expression in expressions {
            guard let preset = expression.preset else { continue }
            #expect(expression.name == preset.rawValue)
        }
    }

    #if compiler(>=6.4)
    /// RealityKit sees only the rest bounds of a mesh deformed on the GPU, so its
    /// occlusion culling is off for those and on for the rest.
    @Test
    func testDeformedMeshesOptOutOfOcclusionCulling() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        let modelEntities = entity.modelEntitiesInHierarchy
        let deformed = modelEntities.filter { $0.deformedMesh?.source.isDeformable == true }
        #expect(!deformed.isEmpty)
        for modelEntity in modelEntities {
            let isCulled = modelEntity.components[OcclusionCullingComponent.self]?.isEnabled ?? true
            #expect(isCulled == (modelEntity.deformedMesh?.source.isDeformable != true), "\(modelEntity.name)")
        }
    }
    #endif
}
#endif
