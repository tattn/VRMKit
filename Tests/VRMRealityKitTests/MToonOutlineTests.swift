#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// The MToon outline seams: the conversion style's width mode, the shader's
/// outline pass policy, and the runtime outline API of ``GLTFEntity``.
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

        // The default stays the world-coordinate outline the converter always drew.
        let world = MToonConversionStyle(outlineWidthFactor: 0.002)
        let worldLoader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                               shaders: [MToonShader(source: .convertAll(world))])
        #expect(try parameters(of: worldLoader).outlineParams.y == 1)
    }

    /// `.automatic` creates a pass only for materials that draw an outline of
    /// their own, and that pass starts enabled.
    @Test
    func testAutomaticOutlinePassFollowsTheAuthoredOutline() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let outlined = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                  shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let pass = try #require(outlineEntities(in: outlined).first)
        #expect(pass.isEnabled)

        // The default style draws no outline, so no pass is built.
        let plain = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                               shaders: [MToonShader(source: .convertAll)]).loadEntity()
        #expect(outlineEntities(in: plain).isEmpty)
    }

    /// `.always` gives every MToon material a pass so an outline can be shown
    /// later; without an authored outline it starts disabled.
    @Test
    func testAlwaysOutlinePassStartsDisabledWithoutAnAuthoredOutline() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll,
                                                                      outlinePass: .always)]).loadEntity()
        let pass = try #require(outlineEntities(in: entity).first)
        #expect(!pass.isEnabled)
    }

    /// `.always` also covers a VRM whose materials are authored without an
    /// outline, which is what makes a runtime selection highlight possible.
    @Test
    func testAlwaysOutlinePassCoversAuthoredMToonWithoutAnOutline() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "no-outline") { mtoon in
            mtoon["outlineWidthMode"] = "none"
        }
        let entity = try await VRMEntityLoader(withData: modified,
                                               shaders: [MToonShader(outlinePass: .always)]).loadEntity()
        let slots = outlineSlotVisibility(in: entity, materialIndex: 0)
        #expect(!slots.isEmpty)
        #expect(slots.allSatisfy { !$0 })

        let automatic = try await VRMEntityLoader(withData: modified).loadEntity()
        #expect(outlineSlotVisibility(in: automatic, materialIndex: 0).isEmpty)
    }

    /// The selection-highlight flow end to end minus the GPU: an override shows
    /// a hidden pass and draws through it, over rows it leaves as authored.
    @Test
    func testOutlineOverrideShowsAHiddenPassAndLeavesTheAuthoredRows() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll,
                                                                      outlinePass: .always)]).loadEntity()

        let pass = try #require(outlineEntities(in: entity).first)
        let authored = try #require(entity.mtoonParameters(forMaterialIndex: 0))
        #expect(!pass.isEnabled)

        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0),
                                             width: 0.004,
                                             mode: .screenCoordinates)
        entity.setMToonOutlineOverride(highlight)

        #expect(pass.isEnabled)
        let state = try #require(entity.mtoonState(forMaterialIndex: 0))
        #expect(state.outlineOverride == highlight)
        // Untouched underneath, which is what lets the override be released.
        #expect(state.parameters.outlineColor == authored.outlineColor)
        #expect(state.parameters.outlineParams == authored.outlineParams)
        // The writes were flushed, not left pending for an expression tick.
        #expect(entity.materialStates.values.allSatisfy { !$0.needsFlush })

        // Releasing it hides the pass that started hidden again.
        entity.setMToonOutlineOverride(nil)
        #expect(state.outlineOverride == nil)
        #expect(!pass.isEnabled)
    }

    /// Re-setting the override already in place must not write the parameter rows
    /// again, and a change that does write them lands in the texture the materials
    /// already sample.
    @Test
    func testSettingTheSameOverrideAgainDoesNotRewriteTheParameterRows() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll,
                                                                      outlinePass: .always)]).loadEntity()
        let state = try #require(entity.mtoonState(forMaterialIndex: 0))

        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004)
        entity.setMToonOutlineOverride(highlight)
        let texture = try #require(state.parameterTexture)
        let writes = texture.writeCount
        #expect(!state.updatesMaterialsOnFlush, "the first flush installs the texture, later ones must not")

        entity.setMToonOutlineOverride(highlight)
        #expect(texture.writeCount == writes)

        // A different override is a real change, so it is written.
        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(0, 1, 0), width: 0.004))
        #expect(texture.writeCount == writes + 1)
        #expect(state.parameterTexture === texture)
    }

    /// A zero-width override outlines nothing, so it hides the passes: the
    /// inverted hull draws wherever its geometry does, offset or not.
    @Test
    func testZeroWidthOverrideHidesThePassesInsteadOfShowingThem() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let passes = outlineEntities(in: entity)
        #expect(passes.allSatisfy { $0.isEnabled }, "the authored outline must start visible")

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0))
        #expect(passes.allSatisfy { !$0.isEnabled })

        // Releasing the override restores the authored outline.
        entity.setMToonOutlineOverride(nil)
        #expect(passes.allSatisfy { $0.isEnabled })
    }

    /// Releasing an override puts each pass back to the state it was built in,
    /// so materials authored with an outline keep theirs.
    @Test
    func testReleasingAnOverrideRestoresEachPassToItsAuthoredVisibility() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Material 0 loses its outline, so the passes start in both states.
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "mixed-outlines") { mtoon in
            mtoon["outlineWidthMode"] = "none"
        }
        let entity = try await VRMEntityLoader(withData: modified,
                                               shaders: [MToonShader(outlinePass: .always)]).loadEntity()
        let authoredVisibility = outlineSlotVisibility(in: entity)
        #expect(authoredVisibility.contains(true))
        #expect(authoredVisibility.contains(false))

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004))
        #expect(outlineSlotVisibility(in: entity).allSatisfy { $0 })

        entity.setMToonOutlineOverride(nil)
        #expect(outlineSlotVisibility(in: entity) == authoredVisibility)
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

        // Both kinds of parameter write rebuild custom.value; neither may drop
        // the budget.
        entity.setMToonLightDirection(SIMD3<Float>(1, 0, 0))
        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004))
        #expect(try budget(of: pass) == margin)
        #expect(try budget(of: main) == 0)
    }

    /// Rows that never reached the GPU must not move the pass visibility. Setting
    /// the same override again retries the flush, and the visibility follows it.
    @Test
    func testPassVisibilityWaitsForTheRowsToReachTheGPU() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll,
                                                                      outlinePass: .always)]).loadEntity()
        let pass = try #require(outlineEntities(in: entity).first)
        #expect(!pass.isEnabled)

        // A material with no state to bake stands in for a parameter texture the
        // GPU has no room for: while it is dirty, no flush finishes.
        let blocked = Int.max
        func blockFlushing(_ isBlocked: Bool) {
            entity.materialStates[blocked] = isBlocked ? .init(needsFlush: true) : nil
        }

        blockFlushing(true)
        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004)
        entity.setMToonOutlineOverride(highlight)
        #expect(try #require(entity.mtoonState(forMaterialIndex: 0)).outlineOverride == highlight)
        #expect(!pass.isEnabled, "shown before the GPU had the override")

        // Setting the same override again is the retry.
        blockFlushing(false)
        entity.setMToonOutlineOverride(highlight)
        #expect(pass.isEnabled)

        blockFlushing(true)
        entity.setMToonOutlineOverride(nil)
        #expect(pass.isEnabled, "hidden while the GPU still drew the override")

        blockFlushing(false)
        entity.setMToonOutlineOverride(nil)
        #expect(!pass.isEnabled)
    }

    /// The override restores the visibility it replaced, not the one the shader
    /// declared, so an outline hidden beforehand does not come back with it.
    @Test
    func testReleasingAnOverrideRestoresTheVisibilityItReplaced() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let passes = outlineEntities(in: entity)
        #expect(passes.allSatisfy { $0.isEnabled }, "the authored outline must start visible")

        entity.setPassEnabled(false, named: MToonShader.outlinePassName)
        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004))
        #expect(passes.allSatisfy { $0.isEnabled })

        entity.setMToonOutlineOverride(nil)
        #expect(passes.allSatisfy { !$0.isEnabled })
    }

    /// Releasing an override that was never set changes nothing, so it does not
    /// undo a ``GLTFEntity/setPassEnabled(_:named:)`` it has nothing to do with.
    @Test
    func testReleasingAnOverrideThatIsNotInForceLeavesPassVisibilityAlone() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let passes = outlineEntities(in: entity)
        #expect(passes.allSatisfy { $0.isEnabled }, "the authored outline must start visible")

        entity.setPassEnabled(false, named: MToonShader.outlinePassName)
        entity.setMToonOutlineOverride(nil)
        #expect(passes.allSatisfy { !$0.isEnabled })

        // And once released, a second release is just as inert.
        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004))
        entity.setMToonOutlineOverride(nil)
        entity.setPassEnabled(false, named: MToonShader.outlinePassName)
        entity.setMToonOutlineOverride(nil)
        #expect(passes.allSatisfy { !$0.isEnabled })
    }

    /// A hidden outline pass still tracks the skeleton, so showing one mid-pose
    /// never draws a frame in the bind pose.
    @Test
    func testHiddenOutlinePassesKeepTrackingTheSkeleton() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                               shaders: [MToonShader(outlinePass: .always)]).loadEntity()
        let hidden = try #require(outlineEntities(in: entity).first {
            $0.components.has(GLTFSkinIndexComponent.self)
                && $0.mergedMesh?.visibleSlots.contains(false) == true
        })
        func pose(of modelEntity: ModelEntity) -> [SIMD4<Float>]? {
            modelEntity.components[SkeletalPosesComponent.self]?.poses.default?
                .jointTransforms.map(\.rotation.vector)
        }

        let restPose = pose(of: hidden)
        entity.humanoid.node(for: .neck)?.transform.rotation *= simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 0, 1))
        entity.flushSkinPose()
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
    /// A recursive clone carries no material runtime state, so visibility still
    /// works on one while the parameter setters are safe no-ops.
    @Test
    func testOutlineVisibilityWorksOnClonesWhileParameterSettersDoNot() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                                shaders: [MToonShader(source: .convertAll,
                                                                      outlinePass: .always)]).loadEntity()
        let clone = entity.clone(recursive: true)
        let clonedPasses = outlineEntities(in: clone)
        #expect(!clonedPasses.isEmpty)
        #expect(clonedPasses.allSatisfy { !$0.isEnabled })

        // The override reaches no parameter rows on a clone, so it must not
        // show the passes either: a whole no-op, not a bare visibility flip.
        clone.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.01))
        #expect(clone.mtoonParameters(forMaterialIndex: 0) == nil)
        #expect(clonedPasses.allSatisfy { !$0.isEnabled })

        clone.setPassEnabled(true, named: MToonShader.outlinePassName)
        #expect(clonedPasses.allSatisfy { $0.isEnabled })
        // The clone owns its own entities, so the original is untouched.
        #expect(outlineEntities(in: entity).allSatisfy { !$0.isEnabled })
    }

    /// A runtime outline color outranks a VRM expression bound to the same value,
    /// and handing it back reveals whatever the expression wrote meanwhile.
    @Test
    func testRuntimeOutlineColorOutranksAnExpressionBind() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let bound = SIMD4<Float>(0, 1, 0, 1)
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "outline-color-bind") { preset in
            guard var happy = preset.object("happy") else {
                throw VRMError.dataInconsistent("Missing Seed-san happy expression")
            }
            happy["materialColorBinds"] = [[
                "material": 0,
                "type": "outlineColor",
                "targetValue": [0.0, 1.0, 0.0, 1.0]
            ]]
            preset["happy"] = .object(happy)
        }
        let entity = try await VRMEntityLoader(withData: modified,
                                               shaders: [MToonShader(outlinePass: .always)]).loadEntity()
        let state = try #require(entity.mtoonState(forMaterialIndex: 0))
        let authored = state.parameters.outlineColor

        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004)
        entity.setMToonOutlineOverride(highlight)
        #expect(state.outlineOverride == highlight)

        // The expression still drives the row underneath; it just does not show.
        entity.setExpression(value: 1, for: .preset(.happy))
        #expect(state.outlineOverride == highlight)
        #expect(state.parameters.outlineColor == bound)

        // Handing it back shows the expression's current color, unprompted.
        entity.setMToonOutlineOverride(nil)
        #expect(state.outlineOverride == nil)
        #expect(state.parameters.outlineColor == bound)

        entity.setExpression(value: 0, for: .preset(.happy))
        #expect(state.parameters.outlineColor == authored)
    }

    // MARK: - Scoped overrides

    /// An override scoped to a material set reaches those materials alone:
    /// the rows, and the pass visibility, of every other material never move.
    @Test
    func testScopedOverrideReachesOnlyItsMaterials() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san materials 0 and 1 both have authored outlines, so a
        // zero-width override on one shows as a change and the other holds.
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        #expect(!outlineSlotVisibility(in: entity, materialIndex: 0).isEmpty)
        #expect(!outlineSlotVisibility(in: entity, materialIndex: 1).isEmpty)

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0),
                                       forMaterials: [0])
        #expect(outlineSlotVisibility(in: entity, materialIndex: 0).allSatisfy { !$0 })
        #expect(outlineSlotVisibility(in: entity, materialIndex: 1).allSatisfy { $0 })
        #expect(try #require(entity.mtoonState(forMaterialIndex: 0)).outlineOverride != nil)
        #expect(try #require(entity.mtoonState(forMaterialIndex: 1)).outlineOverride == nil)

        entity.setMToonOutlineOverride(nil, forMaterials: [0])
        #expect(outlineSlotVisibility(in: entity, materialIndex: 0).allSatisfy { $0 })
        #expect(try #require(entity.mtoonState(forMaterialIndex: 0)).outlineOverride == nil)
    }

    /// Disjoint selections compose, and within an overlap the last set wins per
    /// material while a release restores what the first covering set replaced.
    @Test
    func testScopedOverridesComposePerMaterial() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let state0 = try #require(entity.mtoonState(forMaterialIndex: 0))
        let state1 = try #require(entity.mtoonState(forMaterialIndex: 1))
        let blue = MToonOutlineOverride(color: SIMD3<Float>(0, 0, 1), width: 0.004)
        let white = MToonOutlineOverride(color: SIMD3<Float>(1, 1, 1), width: 0)

        entity.setMToonOutlineOverride(blue, forMaterials: [0, 1])
        entity.setMToonOutlineOverride(white, forMaterials: [1])
        #expect(state0.outlineOverride == blue)
        #expect(state1.outlineOverride == white)
        #expect(outlineSlotVisibility(in: entity, materialIndex: 1).allSatisfy { !$0 })

        // Material 1 goes back to its authored visibility, not to blue's.
        entity.setMToonOutlineOverride(nil, forMaterials: [1])
        #expect(state0.outlineOverride == blue)
        #expect(state1.outlineOverride == nil)
        #expect(outlineSlotVisibility(in: entity, materialIndex: 1).allSatisfy { $0 })

        entity.setMToonOutlineOverride(nil, forMaterials: [0])
        #expect(state0.outlineOverride == nil)
    }

    /// The whole-entity setter is the all-materials scope, so a global release
    /// hands back a scoped override, and a scoped release carves one material
    /// out of a global override.
    @Test
    func testGlobalAndScopedOverridesShareOneScope() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let state0 = try #require(entity.mtoonState(forMaterialIndex: 0))
        let state1 = try #require(entity.mtoonState(forMaterialIndex: 1))
        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004)

        entity.setMToonOutlineOverride(highlight, forMaterials: [0])
        entity.setMToonOutlineOverride(nil)
        #expect(state0.outlineOverride == nil)

        entity.setMToonOutlineOverride(highlight)
        entity.setMToonOutlineOverride(nil, forMaterials: [0])
        #expect(state0.outlineOverride == nil)
        #expect(state1.outlineOverride == highlight)
        entity.setMToonOutlineOverride(nil)
        #expect(state1.outlineOverride == nil)
    }

    /// A scoped release restores the visibility the override replaced, a
    /// global hide of the caller's own included, for its materials alone.
    @Test
    func testScopedReleaseRestoresTheVisibilityItReplacedForItsMaterialsAlone() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        entity.setPassEnabled(false, named: MToonShader.outlinePassName)

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004),
                                       forMaterials: [0])
        #expect(outlineSlotVisibility(in: entity, materialIndex: 0).allSatisfy { $0 })
        #expect(outlineSlotVisibility(in: entity, materialIndex: 1).allSatisfy { !$0 })

        entity.setMToonOutlineOverride(nil, forMaterials: [0])
        #expect(outlineSlotVisibility(in: entity, materialIndex: 0).allSatisfy { !$0 })
    }

    /// A selection of materials the outline runtime does not cover moves no
    /// pass visibility at all, an empty one included.
    @Test
    func testScopedOverrideWithoutAnOutlinePassInTheSelectionIsANoOp() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Under the default `.automatic` pass policy Seed-san material 3 (an
        // outline-less eye) builds no pass, and material 12 is not MToon.
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let visibility = outlineSlotVisibility(in: entity)

        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004)
        entity.setMToonOutlineOverride(highlight, forMaterials: [3, 12])
        #expect(entity.mtoonState(forMaterialIndex: 3)?.outlineOverride == nil)
        #expect(entity.mtoonState(forMaterialIndex: 12) == nil)
        #expect(outlineSlotVisibility(in: entity) == visibility)

        entity.setMToonOutlineOverride(highlight, forMaterials: [])
        #expect(outlineSlotVisibility(in: entity) == visibility)
    }

    /// The unit of a scoped override is the material, so selecting a subtree
    /// whose material is shared outlines everywhere that material draws.
    @Test
    func testASharedMaterialIsOutlinedEverywhereItDraws() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's "hair_tail" mesh (node 1) draws material 0, which the
        // "hair" mesh (node 0) shares.
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hairTail = try #require(entity.entity(forNodeAt: 1))
        let selection = entity.materialIndices(under: hairTail)
        #expect(selection == [0])

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0),
                                       forMaterials: selection)
        let hair = try #require(entity.entity(forNodeAt: 0))
        #expect(outlineSlotVisibility(in: hair, materialIndex: 0).allSatisfy { !$0 })

        entity.setMToonOutlineOverride(nil, forMaterials: selection)
        #expect(outlineSlotVisibility(in: hair, materialIndex: 0).allSatisfy { $0 })
    }
#endif
}
#endif
