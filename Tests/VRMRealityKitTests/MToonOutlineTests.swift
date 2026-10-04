#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// The MToon outline seams: the conversion style's width mode, the shader's
/// outline pass policy, and the pass visibility API of ``GLTFEntity`` on it.
@Suite
@MainActor
struct MToonOutlineTests {

    /// The model entities drawing MToon outline passes, found by component
    /// rather than by the pass entity's name.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func outlineEntities(in root: Entity) -> [ModelEntity] {
        root.modelEntitiesInHierarchy.filter {
            $0.components[GLTFMaterialPassComponent.self]?.name == MToonShader.outlinePassName
        }
    }

    /// The visibility of every MToon outline slot under `root`, restricted to the
    /// slots drawing `materialIndex` when one is given. An outline entity bundles
    /// the outlines of a whole mesh, so per-material checks read its slots.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func outlineSlotVisibility(in root: Entity, materialIndex: Int? = nil) -> [Bool] {
        outlineEntities(in: root).flatMap { entity -> [Bool] in
            guard let merged = entity.mergedMesh,
                  let slots = entity.components[GLTFMaterialSlotsComponent.self]?.materialIndices else {
                return []
            }
            return zip(slots, merged.visibleSlots).compactMap { index, isVisible in
                materialIndex == nil || index == materialIndex ? isVisible : nil
            }
        }
    }

#if !os(visionOS)
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func parameters(of loader: any MaterialInspectingLoader,
                            materialIndex: Int = 0) throws -> MToonMaterialParameters {
        try #require(loader.makeAnimatableMaterialState(forMaterialIndex: materialIndex)
            as? MToonAnimatableMaterialState,
            TestSupport.expectedCustomMaterialMessage).parameters
    }

    /// The conversion style's width mode reaches the packed `outlineParams`
    /// row: `.screenCoordinates` is what `MToon.metal` reads as > 1.5.
    @Test
    func testConversionStyleWidthModeReachesTheParameterRows() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let screen = MToonConversionStyle(outlineWidthMode: .screenCoordinates, outlineWidthFactor: 0.005)
        let screenLoader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll(screen))])
        let screenParams = try parameters(of: screenLoader).outlineParams
        #expect(screenParams.x.isApproximatelyEqual(to: 0.005))
        #expect(screenParams.y == 2)

        // The default width mode is a world-coordinate outline.
        let world = MToonConversionStyle(outlineWidthFactor: 0.002)
        let worldLoader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                               shaders: [MToonShader(source: .convertAll(world))])
        #expect(try parameters(of: worldLoader).outlineParams.y == 1)
    }

    /// `.automatic` creates a pass only for materials that draw an outline of
    /// their own, converted ones included, and that pass starts enabled.
    @Test
    func testAutomaticOutlinePassFollowsTheAuthoredOutline() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let outlined = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                  shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let pass = try #require(outlineEntities(in: outlined).first)
        #expect(pass.isEnabled)
        // Named after the mesh it belongs to, not after the unnamed model entity.
        let mesh = try #require(pass.parent)
        #expect(!mesh.name.isEmpty)
        #expect(pass.name == "\(mesh.name)_\(MToonShader.outlinePassName)")

        // The default style draws no outline, so no pass is built.
        let plain = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                               shaders: [MToonShader(source: .convertAll)]).loadEntity()
        #expect(outlineEntities(in: plain).isEmpty)
    }

    /// The modifier clamps its offset to the margin the pass is culled by, which
    /// the loader writes into `custom.value.w` for every later flush to carry.
    @Test
    func testTheOutlineBudgetMatchesTheCullingMarginAndSurvivesAFlush() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let pass = try #require(outlineEntities(in: entity).first)
        func budget(of modelEntity: ModelEntity) throws -> Float {
            let component = try #require(modelEntity.components[ModelComponent.self])
            let material = try #require(component.materials.first as? CustomMaterial,
                                        TestSupport.expectedCustomMaterialMessage)
            return material.custom.value.w
        }
        let margin = try #require(pass.components[ModelComponent.self]).boundsMargin
        #expect(margin > 0)
        #expect(try budget(of: pass) == margin)

        // The main pass has no geometry modifier, so no budget either.
        let main = try #require(entity.modelEntitiesInHierarchy.first {
            !$0.components.has(GLTFMaterialPassComponent.self)
        })
        #expect(try budget(of: main) == 0)

        // A parameter write rebuilds custom.value; it may not drop the budget.
        entity.setMToonLightDirection(SIMD3<Float>(1, 0, 0))
        entity.setMaterialColor(SIMD4<Float>(1, 0, 0, 1), for: .outlineColor, ofMaterial: 0)
        #expect(try budget(of: pass) == margin)
        #expect(try budget(of: main) == 0)
    }

    /// A hidden outline pass still tracks the skeleton, so showing one mid-pose
    /// never draws a frame in the bind pose.
    @Test
    func testHiddenOutlinePassesKeepTrackingTheSkeleton() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        entity.setPassEnabled(false, named: MToonShader.outlinePassName)
        let hidden = try #require(outlineEntities(in: entity).first {
            $0.components.has(GLTFSkinIndexComponent.self)
        })
        func pose(of modelEntity: ModelEntity) -> [SIMD4<Float>]? {
            modelEntity.deformedMesh?.jointTransforms?.map(\.rotation.vector)
        }

        let restPose = pose(of: hidden)
        entity.humanoid.node(for: .neck)?.transform.rotation *= simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 0, 1))
        entity.invalidateSkinPose()
        entity.updateSkinPose()
        #expect(pose(of: hidden) != restPose)
    }

    /// The runtime API reaches every MToon material of a VRM, and hiding the
    /// outlines leaves the main passes rendering.
    @Test
    func testRuntimeOutlineVisibilityLeavesMainPassesAlone() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let outlines = outlineEntities(in: entity)
        #expect(!outlines.isEmpty, "the fixture must have authored outlines for this to measure anything")

        entity.setPassEnabled(false, named: MToonShader.outlinePassName)
        #expect(outlines.allSatisfy { !$0.isEnabled })
        let mainPasses = entity.modelEntitiesInHierarchy.filter {
            !$0.components.has(GLTFMaterialPassComponent.self)
        }
        #expect(!mainPasses.isEmpty)
        #expect(mainPasses.allSatisfy { $0.isEnabled })
    }

    /// Pass visibility is read from the entity graph, so it works on a recursive
    /// clone, which carries no material runtime state, without reaching the original.
    @Test
    func testOutlineVisibilityWorksOnClones() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let clone = entity.clone(recursive: true)
        let clonedPasses = outlineEntities(in: clone)
        #expect(!clonedPasses.isEmpty)
        #expect(clone.mtoonParameters(forMaterialIndex: 0) == nil)

        clone.setPassEnabled(false, named: MToonShader.outlinePassName)
        #expect(clonedPasses.allSatisfy { !$0.isEnabled })
        #expect(outlineEntities(in: entity).allSatisfy { $0.isEnabled })
    }

    // MARK: - Pass visibility by material

    /// A material set reaches those materials alone, and a reset puts them back.
    @Test
    func testPassVisibilityForMaterialsReachesOnlyThem() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san materials 0 and 1 both have authored outlines, so hiding one
        // shows as a change and the other holds.
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        #expect(!outlineSlotVisibility(in: entity, materialIndex: 0).isEmpty)
        #expect(!outlineSlotVisibility(in: entity, materialIndex: 1).isEmpty)

        entity.setPassEnabled(false, named: MToonShader.outlinePassName, forMaterials: [0])
        #expect(outlineSlotVisibility(in: entity, materialIndex: 0).allSatisfy { !$0 })
        #expect(outlineSlotVisibility(in: entity, materialIndex: 1).allSatisfy { $0 })

        entity.resetPassEnabled(named: MToonShader.outlinePassName, forMaterials: [0])
        #expect(outlineSlotVisibility(in: entity, materialIndex: 0).allSatisfy { $0 })
    }

    /// A reset goes back to the visibility the shader built the pass with, for its
    /// materials alone.
    @Test
    func testResettingPassVisibilityRestoresWhatTheShaderBuilt() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        entity.setPassEnabled(false, named: MToonShader.outlinePassName)

        entity.resetPassEnabled(named: MToonShader.outlinePassName, forMaterials: [0])
        #expect(outlineSlotVisibility(in: entity, materialIndex: 0).allSatisfy { $0 })
        #expect(outlineSlotVisibility(in: entity, materialIndex: 1).allSatisfy { !$0 })

        entity.resetPassEnabled(named: MToonShader.outlinePassName)
        #expect(outlineSlotVisibility(in: entity).allSatisfy { $0 })
    }

    /// Materials that draw no such pass are skipped, an empty selection included.
    @Test
    func testPassVisibilityWithoutThePassInTheSelectionIsANoOp() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san material 3, an eye without an outline, builds no pass, and material
        // 12 is not MToon.
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let visibility = outlineSlotVisibility(in: entity)

        entity.setPassEnabled(false, named: MToonShader.outlinePassName, forMaterials: [3, 12])
        #expect(outlineSlotVisibility(in: entity) == visibility)
        entity.setPassEnabled(false, named: MToonShader.outlinePassName, forMaterials: [])
        #expect(outlineSlotVisibility(in: entity) == visibility)
    }

    /// The unit is the material, so selecting a subtree whose material is shared
    /// reaches everywhere that material draws.
    @Test
    func testPassVisibilityOnASharedMaterialReachesEverywhereItDraws() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's "hair_tail" mesh (node 1) draws material 0, which the
        // "hair" mesh (node 0) shares.
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hairTail = try #require(entity.entity(forNodeAt: 1))
        let selection = entity.materialIndices(under: hairTail)
        #expect(selection == [0])

        entity.setPassEnabled(false, named: MToonShader.outlinePassName, forMaterials: selection)
        let hair = try #require(entity.entity(forNodeAt: 0))
        #expect(outlineSlotVisibility(in: hair, materialIndex: 0).allSatisfy { !$0 })
    }
#endif
}
#endif
