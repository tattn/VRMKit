#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
@testable import VRMRealityKit

@Suite
@MainActor
struct VRMUpdateSystemTests {
    @Test
    func testAutomaticUpdateIsOnByDefaultAndCanBeToggled() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try await loader.loadEntity()
        #expect(vrmEntity.isAutomaticUpdateEnabled)

        vrmEntity.isAutomaticUpdateEnabled = false
        #expect(!vrmEntity.isAutomaticUpdateEnabled)

        vrmEntity.isAutomaticUpdateEnabled = true
        #expect(vrmEntity.isAutomaticUpdateEnabled)
    }

    @Test
    func testParentKeepsTheLoadedEntityAlive() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Adding the model to a scene is all its lifetime needs: nothing outside
        // the entity graph has to hold on to it for the system to keep animating.
        let parent = Entity()
        weak var loaded: VRMEntity?
        do {
            let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
            let vrmEntity = try await loader.loadEntity()
            loaded = vrmEntity
            parent.addChild(vrmEntity)
        }

        #expect(loaded != nil)
        #expect(parent.children.first === loaded)
    }

    /// A model with neither spring bones nor node constraints holds whatever
    /// pose it was last put in, so its per-frame update stops re-solving every
    /// skeleton. Posing a joint directly is what says otherwise.
    @Test
    func testAStaticModelSolvesItsSkinOnlyOnceInvalidated() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.staticSeedSanData()
        let vrmEntity = try await VRMEntityLoader(withData: data, shaders: []).loadEntity()

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        let before = TestSupport.jointRotations(in: vrmEntity)
        #expect(!before.isEmpty)

        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(TestSupport.jointRotations(in: vrmEntity) == before)

        vrmEntity.invalidateSkinPose()
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(TestSupport.jointRotations(in: vrmEntity) != before)
    }

    /// A directly posed joint reaches the skin through the fine-grained
    /// invalidation alone, even against a solve the runtime already has cached:
    /// only the moved joint's row is recomputed, and it lands.
    @Test
    func testDirectlyPosedJointReachesTheSkinThroughAFineGrainedInvalidate() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
        // Warm the per-skeleton solve cache, so the second update takes the
        // partial path rather than a first full solve.
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        let before = TestSupport.jointRotations(in: vrmEntity)
        #expect(!before.isEmpty)
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.invalidateSkinPose(for: [head])
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(TestSupport.jointRotations(in: vrmEntity) != before)
    }

    /// The fine-grained invalidation solves the same pose the whole-model one
    /// does; it only skips the joints nobody moved.
    @Test
    func testFineGrainedInvalidateMatchesAFullReSolve() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func posedRotations(invalidate: (VRMEntity, Entity) -> Void) async throws -> [SIMD4<Float>] {
            let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
            vrmEntity.resetSpringBones()
            vrmEntity.update(deltaTime: 0)
            let neck = try #require(vrmEntity.humanoid.node(for: .neck))
            neck.transform.rotation *= simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0))
            invalidate(vrmEntity, neck)
            vrmEntity.update(deltaTime: 0)
            return TestSupport.jointRotations(in: vrmEntity)
        }

        let fine = try await posedRotations { entity, neck in entity.invalidateSkinPose(for: [neck]) }
        let full = try await posedRotations { entity, _ in entity.invalidateSkinPose() }
        #expect(fine == full)
    }

    /// Moving the model does not turn a fine-grained invalidation back into a whole
    /// re-solve: a joint posed without being named stays out of the skin, exactly as
    /// it does with the model held still.
    @Test
    func testAMovedModelRootKeepsTheInvalidationFineGrained() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.staticSeedSanData(), shaders: []).loadEntity()
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        // A toe sits under no row any skeleton reads through the scene graph, so only
        // a whole re-solve reaches it.
        let toe = try #require(vrmEntity.humanoid.node(for: .leftToes))
        let neck = try #require(vrmEntity.humanoid.node(for: .neck))
        let before = TestSupport.jointRotations(in: vrmEntity)
        #expect(!before.isEmpty)

        toe.transform.rotation *= simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.transform.translation += SIMD3<Float>(0.5, 0, 0.25)
        vrmEntity.invalidateSkinPose(for: [neck])
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(TestSupport.jointRotations(in: vrmEntity) == before)

        // Naming it still lands, so the pose was not merely frozen.
        vrmEntity.invalidateSkinPose(for: [toe])
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(TestSupport.jointRotations(in: vrmEntity) != before)
    }

    /// Solving only the moved rows while the model moves lands the same pose a whole
    /// re-solve does.
    @Test
    func testFineGrainedInvalidateMatchesAFullReSolveWhileTheModelMoves() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func posedRotations(invalidate: (VRMEntity, Entity) -> Void) async throws -> [SIMD4<Float>] {
            let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
            vrmEntity.resetSpringBones()
            vrmEntity.update(deltaTime: 0)
            let neck = try #require(vrmEntity.humanoid.node(for: .neck))
            for step in 1...3 {
                vrmEntity.transform.translation = SIMD3<Float>(Float(step) * 0.1, 0, 0)
                neck.transform.rotation *= simd_quatf(angle: 0.1, axis: SIMD3<Float>(0, 1, 0))
                invalidate(vrmEntity, neck)
                vrmEntity.update(deltaTime: 0)
            }
            return TestSupport.jointRotations(in: vrmEntity)
        }

        let fine = try await posedRotations { entity, neck in entity.invalidateSkinPose(for: [neck]) }
        let full = try await posedRotations { entity, _ in entity.invalidateSkinPose() }
        #expect(fine == full)
    }

    /// A node no skeleton owns can still sit on the path a root row is read
    /// through, so invalidating one re-reads those rows: turning the armature
    /// root reaches the skin without any joint being named.
    @Test
    func testFineGrainedInvalidateForAnUnownedAncestorReachesTheSkin() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        let hips = try #require(vrmEntity.humanoid.node(for: .hips))
        let armatureRoot = try #require(hips.parent)
        let before = TestSupport.jointRotations(in: vrmEntity)
        #expect(!before.isEmpty)
        armatureRoot.transform.rotation *= simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(0, 1, 0))
        vrmEntity.invalidateSkinPose(for: [armatureRoot])
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(TestSupport.jointRotations(in: vrmEntity) != before)
    }
}
#endif
