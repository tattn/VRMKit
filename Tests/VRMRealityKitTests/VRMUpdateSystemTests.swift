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
    func testParentKeepsTheLoadedEntityAlive() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Adding the model to a scene is all its lifetime needs: nothing outside
        // the entity graph has to hold on to it for the system to keep animating.
        let parent = Entity()
        weak var loaded: VRMEntity?
        do {
            let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: [])
            let vrmEntity = try await loader.loadEntity()
            #expect(vrmEntity.isAutomaticUpdateEnabled)
            vrmEntity.isAutomaticUpdateEnabled = false
            #expect(!vrmEntity.isAutomaticUpdateEnabled)
            vrmEntity.isAutomaticUpdateEnabled = true
            #expect(vrmEntity.isAutomaticUpdateEnabled)

            loaded = vrmEntity
            parent.addChild(vrmEntity)
        }

        #expect(loaded != nil)
        #expect(parent.children.first === loaded)
    }

    /// A model with neither spring bones nor node constraints holds whatever pose it was
    /// last put in, so its per-frame update moves nothing for the skin to re-solve, while a
    /// joint posed on its entity reaches the skin on the next update.
    @Test
    func testAStaticModelResolvesItsSkinOnlyWhenAJointMoves() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.staticSeedSanData()
        let vrmEntity = try await VRMEntityLoader(withData: data, shaders: []).loadEntity()
        let pose = try #require(vrmEntity.pose)

        vrmEntity.update(deltaTime: 1.0 / 60.0)
        let before = TestSupport.jointRotations(in: vrmEntity)
        #expect(!before.isEmpty)
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(!pose.hasNodesMovedForSkinning)
        #expect(TestSupport.jointRotations(in: vrmEntity) == before)

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(TestSupport.jointRotations(in: vrmEntity) != before)
    }

    /// The skin is solved in the model's own space, so moving the model moves no row.
    @Test
    func testMovingTheModelRootLeavesTheSkinPose() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.staticSeedSanData(), shaders: []).loadEntity()
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        let before = TestSupport.jointRotations(in: vrmEntity)
        #expect(!before.isEmpty)

        vrmEntity.transform.translation += SIMD3<Float>(0.5, 0, 0.25)
        vrmEntity.transform.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(TestSupport.jointRotations(in: vrmEntity) == before)
    }

    /// The fine-grained invalidation solves the same pose the whole-model one
    /// does, with the model held still or moving; it only skips the joints
    /// nobody moved.
    @Test(arguments: [false, true])
    func testFineGrainedInvalidateMatchesAFullReSolve(whileTheModelMoves moving: Bool) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func posedRotations(invalidate: (VRMEntity, Entity) -> Void) async throws -> [SIMD4<Float>] {
            let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
            vrmEntity.resetSpringBones()
            vrmEntity.update(deltaTime: 0)
            let neck = try #require(vrmEntity.humanoid.node(for: .neck))
            for step in 1...(moving ? 3 : 1) {
                if moving {
                    vrmEntity.transform.translation = SIMD3<Float>(Float(step) * 0.1, 0, 0)
                }
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
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.staticSeedSanData(), shaders: []).loadEntity()
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

    /// Code set to pose the model runs at its stage of each update, with the frame's time,
    /// and what it writes to the pose reaches the skin in that same update.
    @Test
    func testUpdateHandlersRunAtTheirStagesAndReachTheSkin() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.staticSeedSanData(), shaders: []).loadEntity()
        let pose = try #require(vrmEntity.pose)
        let head = try #require(vrmEntity.humanoid.nodeIndex(for: .head))
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        let before = TestSupport.jointRotations(in: vrmEntity)

        var calls: [(VRMUpdateStage, TimeInterval)] = []
        let turn = simd_quatf(angle: 0.5, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.setUpdateHandler({ deltaTime in
            calls.append((.afterAnimation, deltaTime))
            pose.setLocalRotation(turn, ofNode: head)
        }, at: .afterAnimation)
        vrmEntity.setUpdateHandler({ calls.append((.beforeSkinning, $0)) }, at: .beforeSkinning)
        vrmEntity.update(deltaTime: 0.02)

        #expect(calls.map(\.0) == [.afterAnimation, .beforeSkinning])
        #expect(calls.allSatisfy { $0.1 == 0.02 })
        #expect(TestSupport.jointRotations(in: vrmEntity) != before)

        vrmEntity.setUpdateHandler(nil, at: .afterAnimation)
        vrmEntity.setUpdateHandler(nil, at: .beforeSkinning)
        calls.removeAll()
        vrmEntity.update(deltaTime: 0.02)
        #expect(calls.isEmpty)
    }


    /// Settling a held pose swings the spring bones without advancing the animations or running
    /// the code that poses the model each frame.
    @Test
    func testSecondaryMotionLeavesAnimationsAndHandlersAlone() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
        var handled = false
        vrmEntity.setUpdateHandler({ _ in handled = true }, at: .afterAnimation)
        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        let before = TestSupport.jointRotations(in: vrmEntity)

        vrmEntity.updateSecondaryMotion(deltaTime: 1.0 / 60.0)
        #expect(!handled)
        #expect(TestSupport.jointRotations(in: vrmEntity) != before)
    }

}
#endif
