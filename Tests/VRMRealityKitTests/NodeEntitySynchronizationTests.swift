#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import simd
@testable import VRMRealityKit

/// How far a model's node entities follow its pose.
@Suite
@MainActor
struct NodeEntitySynchronizationTests {
    /// Narrowed to the head, the head and the bones above it keep following the pose, the
    /// rest of the node entities stay where they were, and the skin follows the whole pose.
    @Test
    func testNarrowedSynchronizationKeepsOnlyTheNamedNodesAndTheirAncestors() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.staticSeedSanStandard).loadEntity()
        let pose = try #require(entity.pose)
        func index(_ bone: HumanoidBone) throws -> Int {
            try #require(entity.humanoid.nodeIndex(for: bone))
        }
        let head = try index(.head), hips = try index(.hips), toe = try index(.leftToes)
        entity.nodeEntitySynchronization = .nodes([head])
        entity.update(deltaTime: 1.0 / 60.0)
        let skinBefore = TestSupport.jointRotations(in: entity)
        let toeEntityBefore = try #require(entity.entity(forNodeAt: toe)).transform

        let turn = simd_quatf(angle: 0.4, axis: SIMD3(0, 1, 0))
        pose.setLocalRotation(turn, ofNode: hips)
        pose.setLocalRotation(turn, ofNode: toe)
        entity.update(deltaTime: 1.0 / 60.0)

        #expect(abs(simd_dot(try #require(entity.entity(forNodeAt: hips)).transform.rotation, turn)) > 0.9999)
        #expect(try #require(entity.entity(forNodeAt: toe)).transform == toeEntityBefore)
        #expect(TestSupport.jointRotations(in: entity) != skinBefore)
    }

    /// Widening the synchronization again copies the pose into the entities it left behind.
    @Test
    func testWideningSynchronizationCatchesTheEntitiesUp() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.staticSeedSanStandard).loadEntity()
        let pose = try #require(entity.pose)
        let toe = try #require(entity.humanoid.nodeIndex(for: .leftToes))
        entity.nodeEntitySynchronization = .nodes([])
        let turn = simd_quatf(angle: 0.4, axis: SIMD3(1, 0, 0))
        pose.setLocalRotation(turn, ofNode: toe)
        #expect(abs(simd_dot(try #require(entity.entity(forNodeAt: toe)).transform.rotation, turn)) < 0.9999)

        entity.nodeEntitySynchronization = .all
        #expect(abs(simd_dot(try #require(entity.entity(forNodeAt: toe)).transform.rotation, turn)) > 0.9999)
    }

    /// A copy of the model is taken with its node entities where the pose puts them, so
    /// what hangs under a bone is copied in place even when that bone was not kept.
    @Test
    func testACopyCarriesThePoseInItsNodeEntities() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.staticSeedSanStandard).loadEntity()
        let pose = try #require(entity.pose)
        let toe = try #require(entity.humanoid.nodeIndex(for: .leftToes))
        entity.nodeEntitySynchronization = .nodes([])
        let turn = simd_quatf(angle: 0.4, axis: SIMD3(1, 0, 0))
        pose.setLocalRotation(turn, ofNode: toe)

        let copy = entity.snapshot()
        let toeName = try #require(entity.entity(forNodeAt: toe)).name
        let copiedToe = try #require(copy.findEntity(named: toeName))
        #expect(abs(simd_dot(copiedToe.transform.rotation, turn)) > 0.9999)
    }
}
#endif
