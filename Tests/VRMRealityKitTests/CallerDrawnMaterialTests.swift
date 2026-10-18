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

    /// Showing and hiding a pass stays with the app while the caller draws it: the caller reads it
    /// off ``GLTFMaterialGeometry/isVisible``, and RealityKit takes the pass back as the app left it.
    @Test
    func testPassVisibilityOutlivesDrawingByTheCaller() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), TestSupport.isMToonRenderingAvailable else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let materials = Set(entity.gltf.materials.indices)
        func outlines() -> [GLTFMaterialGeometry] {
            materials.flatMap { entity.geometry(ofMaterial: $0) }.filter { $0.passName == MToonShader.outlinePassName }
        }
        let shown = try #require(outlines().first { $0.isVisible })

        entity.setDrawnByCaller(true, forMaterials: materials)
        entity.setPassEnabled(false, named: MToonShader.outlinePassName)
        #expect(!outlines().contains { $0.isVisible })
        #expect(materials.flatMap { entity.geometry(ofMaterial: $0) }.contains { $0.passName == nil && $0.isVisible })

        // RealityKit draws a slot while its entity is enabled and the parts hold it: a mesh left
        // with nothing to draw keeps its last parts and disables the entity instead.
        func drawnByRealityKit(_ geometry: GLTFMaterialGeometry) -> Bool {
            geometry.modelEntity.isEnabled && geometry.mesh.parts.contains { $0.materialIndex == geometry.materialSlot }
        }
        entity.setDrawnByCaller(false, forMaterials: materials)
        #expect(!drawnByRealityKit(shown))
        entity.setPassEnabled(true, named: MToonShader.outlinePassName)
        #expect(shown.isVisible)
        #expect(drawnByRealityKit(shown))
    }

    /// A caller draws what a first-person camera sees when asked to, and nothing of a mesh
    /// whose entity is disabled.
    @Test
    func testGeometryFollowsTheFirstPersonCutAndTheEntityTree() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Alicia annotates every mesh `Auto`, hers being split head from body.
        let entity = try await VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data, shaders: []).loadEntity()
        let cut = try #require(TestSupport.firstPersonCuts(in: entity).first {
            TestSupport.triangleIndexCount(of: $0.gltfMeshGeometry!, isFirstPerson: true) > 0
        })
        let materials = entity.materialIndices(under: cut)
        let geometry = materials.flatMap { entity.geometry(ofMaterial: $0) }.filter { $0.modelEntity === cut }
        entity.setDrawnByCaller(true, forMaterials: materials)
        let thirdPerson = geometry.map(\.indexRange)

        entity.setFirstPersonRenderMode(.firstPerson)
        let firstPerson = geometry.map(\.indexRange)
        #expect(zip(firstPerson, thirdPerson).contains { $0.count < $1.count })
        #expect(zip(firstPerson, thirdPerson).allSatisfy { $0.count <= $1.count })
        entity.setFirstPersonRenderMode(.thirdPerson)
        #expect(geometry.map(\.indexRange) == thirdPerson)

        #expect(geometry.allSatisfy { $0.isVisible })
        entity.isEnabled = false
        #expect(!geometry.contains { $0.isVisible })
    }

    /// The geometry says how the loader draws the material: an opaque eye and the blended
    /// highlight over it, which draws at its MToon render queue.
    @Test
    func testGeometrySaysHowTheMaterialDraws() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let opaqueEye = 3
        let blendedEye = 4

        for geometry in entity.geometry(ofMaterial: opaqueEye) {
            #expect(geometry.alphaMode == .OPAQUE)
            #expect(geometry.renderQueue == nil)
        }
        let blended = entity.geometry(ofMaterial: blendedEye)
        #expect(!blended.isEmpty)
        for geometry in blended {
            #expect(geometry.alphaMode == .BLEND)
            #expect(geometry.renderQueue == 3000)
        }

        let copy = entity.cloneWithOwnMaterialParameters()
        #expect(copy.geometry(ofMaterial: blendedEye).allSatisfy { $0.alphaMode == .BLEND && $0.renderQueue == 3000 })
    }

    /// The MToon rows a caller reads are the ones the GPU gets, as each change leaves them.
    @Test
    func testMToonParameterRowsFollowEveryFlush() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), TestSupport.isMToonRenderingAvailable else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let state = try #require(entity.materialState(MToonAnimatableMaterialState.self, ofMaterial: 0))
        #expect(state.parameterRows == state.parameters.packedRows)

        let color = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        entity.setMaterialColor(color, for: .color, ofMaterial: 0)
        #expect(state.parameterRows[MToonParameterRow.baseColor.rawValue] == color)
        #expect(state.parameterRows == state.parameters.packedRows)
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
