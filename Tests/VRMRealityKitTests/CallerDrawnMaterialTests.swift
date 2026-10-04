#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Materials an app draws with Metal itself: RealityKit stops drawing them, their
/// vertices keep deforming, and ``GLTFEntity/geometry(ofMaterial:)`` says where they are.
@Suite
@MainActor
struct CallerDrawnMaterialTests {
    @Test
    func testMaterialsDrawnByTheCallerKeepDeforming() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let skinned = try #require(entity.modelEntitiesInHierarchy.first {
            $0.components.has(GLTFSkinIndexComponent.self) && !$0.components.has(GLTFMaterialPassComponent.self)
        })
        let materials = entity.materialIndices(under: skinned)

        entity.setDrawnByCaller(true, forMaterials: materials)
        #expect(!skinned.isEnabled)
        for index in materials {
            #expect(entity.geometry(ofMaterial: index).contains { $0.modelEntity === skinned && !$0.indexRange.isEmpty })
        }
        entity.humanoid.node(for: .hips)?.transform.rotation *= simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        entity.invalidateSkinPose()
        entity.flushSkinPoseIfNeeded()
        #expect(skinned.deformedMesh?.isDeformationPending == true)

        entity.setDrawnByCaller(false, forMaterials: materials)
        #expect(skinned.isEnabled)
    }

    /// The ranges are the material's own triangles in the mesh's index buffer, in the material
    /// itself and in its outline pass, which says its name. Without MToon there is no outline pass.
    @Test
    func testGeometryOfAMaterialIsItsTrianglesInEachPass() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        let geometry = entity.geometry(ofMaterial: 0)

        #expect(geometry.contains { $0.passName == nil })
        #expect(geometry.contains { $0.passName == MToonShader.outlinePassName } == TestSupport.isMToonRenderingAvailable)
        for part in geometry {
            #expect(part.passName == part.modelEntity.components[GLTFMaterialPassComponent.self]?.name)
            #expect(part.indexRange.upperBound <= part.mesh.descriptor.indexCapacity)
            #expect(part.mesh.parts.contains { $0.materialIndex == part.materialSlot })
        }
    }
}
#endif
