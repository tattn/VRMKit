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
    private func outlineEntities(in root: Entity, materialIndex: Int? = nil) -> [ModelEntity] {
        root.modelEntitiesInHierarchy.filter { entity in
            guard entity.components[GLTFMaterialPassComponent.self]?.name == MToonShader.outlinePassName else {
                return false
            }
            guard let materialIndex else { return true }
            return entity.components[GLTFMaterialIndexComponent.self]?.materialIndex == materialIndex
        }
    }

#if !os(visionOS)
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func parameters(of loader: GLTFEntityLoader,
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
    func testAutomaticOutlinePassFollowsTheAuthoredOutline() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let outlined = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                            shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let pass = try #require(outlineEntities(in: outlined).first)
        #expect(pass.isEnabled)

        // The default style draws no outline, so no pass is built.
        let plain = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                         shaders: [MToonShader(source: .convertAll)]).loadEntity()
        #expect(outlineEntities(in: plain).isEmpty)
    }

    /// `.always` gives every MToon material a pass so an outline can be shown
    /// later; without an authored outline it starts disabled.
    @Test
    func testAlwaysOutlinePassStartsDisabledWithoutAnAuthoredOutline() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                          shaders: [MToonShader(source: .convertAll,
                                                                outlinePass: .always)]).loadEntity()
        let pass = try #require(outlineEntities(in: entity).first)
        #expect(!pass.isEnabled)
    }

    /// `.always` also covers a VRM whose materials are authored without an
    /// outline, such as a re-opened model with accessories baked in, which is
    /// what makes a runtime selection highlight possible there.
    @Test
    func testAlwaysOutlinePassCoversAuthoredMToonWithoutAnOutline() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "no-outline") { mtoon in
            mtoon["outlineWidthMode"] = "none"
        }
        let entity = try VRMEntityLoader(withData: modified,
                                         shaders: [MToonShader(outlinePass: .always)]).loadEntity()
        let passes = outlineEntities(in: entity, materialIndex: 0)
        #expect(!passes.isEmpty)
        #expect(passes.allSatisfy { !$0.isEnabled })

        let automatic = try VRMEntityLoader(withData: modified).loadEntity()
        #expect(outlineEntities(in: automatic, materialIndex: 0).isEmpty)
    }

    /// The selection-highlight flow end to end minus the GPU: an override shows
    /// a hidden pass and draws through it, over rows it leaves as authored.
    @Test
    func testOutlineOverrideShowsAHiddenPassAndLeavesTheAuthoredRows() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
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

    /// Re-setting the override already in place must not rebake the parameter
    /// texture: the material keeps the very texture the first set baked.
    @Test
    func testSettingTheSameOverrideAgainDoesNotRebakeTheParameterTexture() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
                                          shaders: [MToonShader(source: .convertAll,
                                                                outlinePass: .always)]).loadEntity()
        let state = try #require(entity.mtoonState(forMaterialIndex: 0))

        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004)
        entity.setMToonOutlineOverride(highlight)
        let baked = try #require(state.bakedTexture?.resource)

        entity.setMToonOutlineOverride(highlight)
        #expect(state.bakedTexture?.resource === baked)

        // A different override is a real change, so it does bake.
        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(0, 1, 0), width: 0.004))
        #expect(state.bakedTexture?.resource !== baked)
    }

    /// A zero-width override outlines nothing, so it hides the passes: the
    /// inverted hull's surface draws wherever its geometry does, offset or not,
    /// which on an open mesh would paint back faces in the outline color.
    @Test
    func testZeroWidthOverrideHidesThePassesInsteadOfShowingThem() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
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
    func testReleasingAnOverrideRestoresEachPassToItsAuthoredVisibility() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Material 0 loses its outline, so the passes start in both states.
        let modified = try TestSupport.modifiedSeedSanMToonExtension(name: "mixed-outlines") { mtoon in
            mtoon["outlineWidthMode"] = "none"
        }
        let entity = try VRMEntityLoader(withData: modified,
                                         shaders: [MToonShader(outlinePass: .always)]).loadEntity()
        let passes = outlineEntities(in: entity)
        let authoredVisibility = passes.map(\.isEnabled)
        #expect(authoredVisibility.contains(true))
        #expect(authoredVisibility.contains(false))

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004))
        #expect(passes.allSatisfy { $0.isEnabled })

        entity.setMToonOutlineOverride(nil)
        #expect(passes.map(\.isEnabled) == authoredVisibility)
    }

    /// The modifier clamps its offset to the very margin the pass is culled by,
    /// so the loader writes that margin into the material. It rides in
    /// `custom.value.w`, which every later parameter flush carries over.
    @Test
    func testTheOutlineBudgetMatchesTheCullingMarginAndSurvivesAFlush() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
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

    /// Rows that never reached the GPU must not move the pass visibility: a
    /// pass shown early draws what is underneath the override, one hidden early
    /// takes away an outline still being drawn. Setting the same override again
    /// retries the flush, and the visibility follows it.
    @Test
    func testPassVisibilityWaitsForTheRowsToReachTheGPU() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
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
    func testReleasingAnOverrideRestoresTheVisibilityItReplaced() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
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
    func testReleasingAnOverrideThatIsNotInForceLeavesPassVisibilityAlone() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let style = MToonConversionStyle(outlineWidthFactor: 0.002)
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
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
    func testHiddenOutlinePassesKeepTrackingTheSkeleton() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData,
                                         shaders: [MToonShader(outlinePass: .always)]).loadEntity()
        let hidden = try #require(outlineEntities(in: entity).first {
            !$0.isEnabled && $0.components.has(GLTFSkinIndexComponent.self)
        })
        func pose(of modelEntity: ModelEntity) -> [SIMD4<Float>]? {
            modelEntity.components[SkeletalPosesComponent.self]?.poses.default?
                .jointTransforms.map(\.rotation.vector)
        }

        let restPose = pose(of: hidden)
        entity.humanoid.node(for: .neck)?.transform.rotation *= simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 0, 1))
        entity.updateSkinning()
        #expect(pose(of: hidden) != restPose)
    }

    /// The runtime API reaches every MToon material of a VRM, and hiding the
    /// outlines leaves the main passes rendering.
    @Test
    func testRuntimeOutlineVisibilityLeavesMainPassesAlone() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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
    /// A recursive clone renders but carries no material runtime state, so
    /// visibility — read from the entity graph — still works on one, while the
    /// setters that write parameter rows are safe no-ops.
    @Test
    func testOutlineVisibilityWorksOnClonesWhileParameterSettersDoNot() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url,
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

    /// A runtime outline color outranks a VRM expression bound to the same
    /// value, so a selection highlight survives the model changing expression.
    /// Handing the color back reveals whatever the expression wrote meanwhile,
    /// not the color the override started from.
    @Test
    func testRuntimeOutlineColorOutranksAnExpressionBind() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let bound = SIMD4<Float>(0, 1, 0, 1)
        let modified = try TestSupport.modifiedSeedSanExpressions(name: "outline-color-bind") { preset in
            guard var happy = preset["happy"] as? [String: Any] else {
                throw VRMError.dataInconsistent("Missing Seed-san happy expression")
            }
            happy["materialColorBinds"] = [[
                "material": 0,
                "type": "outlineColor",
                "targetValue": [0.0, 1.0, 0.0, 1.0]
            ]]
            preset["happy"] = happy
        }
        let entity = try VRMEntityLoader(withData: modified,
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
    func testScopedOverrideReachesOnlyItsMaterials() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san materials 0 and 1 both have authored outlines, so a
        // zero-width override on one shows as a change and the other holds.
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let selected = outlineEntities(in: entity, materialIndex: 0)
        let others = outlineEntities(in: entity, materialIndex: 1)
        #expect(!selected.isEmpty)
        #expect(!others.isEmpty)

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0),
                                       forMaterials: [0])
        #expect(selected.allSatisfy { !$0.isEnabled })
        #expect(others.allSatisfy { $0.isEnabled })
        #expect(try #require(entity.mtoonState(forMaterialIndex: 0)).outlineOverride != nil)
        #expect(try #require(entity.mtoonState(forMaterialIndex: 1)).outlineOverride == nil)

        entity.setMToonOutlineOverride(nil, forMaterials: [0])
        #expect(selected.allSatisfy { $0.isEnabled })
        #expect(try #require(entity.mtoonState(forMaterialIndex: 0)).outlineOverride == nil)
    }

    /// Disjoint selections compose, and within an overlap the last set wins
    /// per material while a release restores what the first covering set
    /// replaced — the authored outline, not the earlier override.
    @Test
    func testScopedOverridesComposePerMaterial() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let state0 = try #require(entity.mtoonState(forMaterialIndex: 0))
        let state1 = try #require(entity.mtoonState(forMaterialIndex: 1))
        let blue = MToonOutlineOverride(color: SIMD3<Float>(0, 0, 1), width: 0.004)
        let white = MToonOutlineOverride(color: SIMD3<Float>(1, 1, 1), width: 0)

        entity.setMToonOutlineOverride(blue, forMaterials: [0, 1])
        entity.setMToonOutlineOverride(white, forMaterials: [1])
        #expect(state0.outlineOverride == blue)
        #expect(state1.outlineOverride == white)
        #expect(outlineEntities(in: entity, materialIndex: 1).allSatisfy { !$0.isEnabled })

        // Material 1 goes back to its authored visibility, not to blue's.
        entity.setMToonOutlineOverride(nil, forMaterials: [1])
        #expect(state0.outlineOverride == blue)
        #expect(state1.outlineOverride == nil)
        #expect(outlineEntities(in: entity, materialIndex: 1).allSatisfy { $0.isEnabled })

        entity.setMToonOutlineOverride(nil, forMaterials: [0])
        #expect(state0.outlineOverride == nil)
    }

    /// The whole-entity setter is the all-materials scope, so a global release
    /// hands back a scoped override, and a scoped release carves one material
    /// out of a global override.
    @Test
    func testGlobalAndScopedOverridesShareOneScope() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
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

    /// A scoped release restores the visibility the override replaced — a
    /// global hide of the caller's own included — for its materials alone.
    @Test
    func testScopedReleaseRestoresTheVisibilityItReplacedForItsMaterialsAlone() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        entity.setPassEnabled(false, named: MToonShader.outlinePassName)

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004),
                                       forMaterials: [0])
        #expect(outlineEntities(in: entity, materialIndex: 0).allSatisfy { $0.isEnabled })
        #expect(outlineEntities(in: entity, materialIndex: 1).allSatisfy { !$0.isEnabled })

        entity.setMToonOutlineOverride(nil, forMaterials: [0])
        #expect(outlineEntities(in: entity, materialIndex: 0).allSatisfy { !$0.isEnabled })
    }

    /// A selection of materials the outline runtime does not cover moves no
    /// pass visibility at all, an empty one included.
    @Test
    func testScopedOverrideWithoutAnOutlinePassInTheSelectionIsANoOp() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Under the default `.automatic` pass policy Seed-san material 3 (an
        // outline-less eye) builds no pass, and material 12 is not MToon.
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let passes = outlineEntities(in: entity)
        let visibility = passes.map(\.isEnabled)

        let highlight = MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0.004)
        entity.setMToonOutlineOverride(highlight, forMaterials: [3, 12])
        #expect(entity.mtoonState(forMaterialIndex: 3)?.outlineOverride == nil)
        #expect(entity.mtoonState(forMaterialIndex: 12) == nil)
        #expect(passes.map(\.isEnabled) == visibility)

        entity.setMToonOutlineOverride(highlight, forMaterials: [])
        #expect(passes.map(\.isEnabled) == visibility)
    }

    /// The unit of a scoped override is the material, so selecting a subtree
    /// whose material is shared outlines everywhere that material draws.
    @Test
    func testASharedMaterialIsOutlinedEverywhereItDraws() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Seed-san's "hair_tail" mesh (node 1) draws material 0, which the
        // "hair" mesh (node 0) shares.
        let entity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let hairTail = try #require(entity.entity(forNodeAt: 1))
        let selection = entity.materialIndices(under: hairTail)
        #expect(selection == [0])

        entity.setMToonOutlineOverride(MToonOutlineOverride(color: SIMD3<Float>(1, 0, 0), width: 0),
                                       forMaterials: selection)
        let hair = try #require(entity.entity(forNodeAt: 0))
        #expect(outlineEntities(in: hair, materialIndex: 0).allSatisfy { !$0.isEnabled })

        entity.setMToonOutlineOverride(nil, forMaterials: selection)
        #expect(outlineEntities(in: hair, materialIndex: 0).allSatisfy { $0.isEnabled })
    }
#endif
}
#endif
