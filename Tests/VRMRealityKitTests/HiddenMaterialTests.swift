#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Materials an app keeps RealityKit from drawing, such as ones it shows in an image of its own.
@Suite
@MainActor
struct HiddenMaterialTests {
    /// A mesh left with nothing to draw disables its entity, and stops deforming meanwhile.
    @Test
    func testHidingEveryMaterialOfAMeshDisablesItsEntity() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.seedSan).loadEntity()
        let skinned = try #require(entity.modelEntitiesInHierarchy.first {
            $0.components.has(GLTFSkinIndexComponent.self) && !$0.components.has(GLTFMaterialPassComponent.self)
        })
        let materials = entity.materialIndices(under: skinned)

        entity.setMaterialsHidden(true, forMaterials: materials)
        #expect(!skinned.isEnabled)
        entity.humanoid.node(for: .hips)?.transform.rotation *= simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        entity.invalidateSkinPose()
        entity.flushSkinPoseIfNeeded()
        #expect(skinned.deformedMesh?.isDeformationPending == false)

        entity.setMaterialsHidden(false, forMaterials: materials)
        #expect(skinned.isEnabled)
        #expect(skinned.deformedMesh?.isDeformationPending == true)
    }

    /// A hidden material stays hidden whatever ``GLTFEntity/setPassEnabled(_:named:forMaterials:)``
    /// says, and shows its passes as the app left them once shown again. A copy keeps it hidden.
    @Test
    func testHiddenMaterialsOutlivePassVisibility() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), TestSupport.isMToonRenderingAvailable else { return }
        let entity = try await TestSupport.sharedLoader(.seedSan).loadEntity()
        let materials = Set(entity.gltf.materials.indices)
        func outlineSlots(of root: Entity) -> [(ModelEntity, Int)] {
            root.modelEntitiesInHierarchy
                .filter { $0.components[GLTFMaterialPassComponent.self]?.name == MToonShader.outlinePassName }
                .flatMap { model in (model.model?.materials.indices ?? 0..<0).map { (model, $0) } }
        }
        // RealityKit draws a slot while its entity is enabled and the parts hold it: a mesh left
        // with nothing to draw keeps its last parts and disables the entity instead.
        func isDrawn(_ slot: (ModelEntity, Int)) -> Bool {
            slot.0.isEnabled && slot.0.deformedMesh?.lowLevelMesh.parts.contains { $0.materialIndex == slot.1 } == true
        }
        let shown = try #require(outlineSlots(of: entity).first(where: isDrawn))

        entity.setMaterialsHidden(true, forMaterials: materials)
        #expect(!isDrawn(shown))
        entity.setPassEnabled(true, named: MToonShader.outlinePassName)
        #expect(!isDrawn(shown))
        let copy = entity.clone(recursive: true)
        #expect(!outlineSlots(of: copy).contains(where: isDrawn))

        entity.setPassEnabled(false, named: MToonShader.outlinePassName)
        entity.setMaterialsHidden(false, forMaterials: materials)
        #expect(!isDrawn(shown))
        entity.setPassEnabled(true, named: MToonShader.outlinePassName)
        #expect(isDrawn(shown))
    }
}
#endif
