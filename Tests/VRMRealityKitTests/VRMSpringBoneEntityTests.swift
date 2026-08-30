#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// The spring bones of a loaded model, swung by ``VRMEntity/update(deltaTime:)``
/// and written back onto the skeletal poses RealityKit draws with.
@Suite
@MainActor
struct VRMSpringBoneEntityTests {
    @Test
    func testUpdateAppliesSpringBonePosesWithoutAFrameOfLag() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: []).loadEntity()

        // Rotating a parent bone drags the spring chains, so spring bones write
        // new joint transforms during update().
        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.invalidateSkinPose(for: [head])
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        var checkedJoints = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let model = modelEntity.components[ModelComponent.self],
                  let skeleton = model.mesh.contents.skeletons.first,
                  let pose = modelEntity.components[SkeletalPosesComponent.self]?.poses.default,
                  pose.jointTransforms.count == skeleton.joints.count else {
                continue
            }
            let jointEntities = skeleton.joints.map { vrmEntity.findEntity(named: $0.name) }
            let jointWorlds = jointEntities.map { $0?.transformMatrix(relativeTo: nil) }
            let modelWorldInverse = modelEntity.transformMatrix(relativeTo: nil).inverse

            for index in skeleton.joints.indices {
                guard let jointWorld = jointWorlds[index] else { continue }
                let expected: simd_float4x4
                if let parentIndex = skeleton.joints[index].parentIndex,
                   let parentWorld = jointWorlds[parentIndex] {
                    expected = parentWorld.inverse * jointWorld
                } else {
                    expected = modelWorldInverse * jointWorld
                }
                // The pose must describe the hierarchy as it stands after
                // update(), not as it stood before the spring bones ran.
                #expect(pose.jointTransforms[index].matrix.isApproximatelyEqual(to: expected, tolerance: 0.0005))
                checkedJoints += 1
            }
        }
        #expect(checkedJoints > 0)
    }

    /// `VRMC_springBone` pairs the joints of a spring consecutively, so the
    /// last of them is only the tail the one before it swings towards.
    @Test
    func testTheLastJointOfASpringIsOnlyItsTail() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()
        guard case .v1(let vrm1) = vrmEntity.vrm else {
            Issue.record("Seed-san is a VRM 1.0 fixture")
            return
        }
        let springs = try #require(vrm1.springBone?.springs)
        let swinging = Set(springs.flatMap { $0.joints.dropLast().map(\.node) })
        // A tail that another spring swings is one this cannot answer for.
        let tailsOnly = Set(springs.compactMap { $0.joints.last?.node }).subtracting(swinging)
        #expect(!tailsOnly.isEmpty)
        let tails = tailsOnly.compactMap { vrmEntity.entity(forNodeAt: $0) }
        let heads = swinging.compactMap { vrmEntity.entity(forNodeAt: $0) }
        let tailRotations = tails.map(\.transform.rotation)
        let headRotations = heads.map(\.transform.rotation)

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(tails.map(\.transform.rotation) == tailRotations)
        // Not an expectation a model standing still would meet anyway.
        #expect(heads.map(\.transform.rotation) != headRotations)
    }

    /// A spring of one joint has no pair in it, so there is nothing to swing.
    @Test
    func testASpringOfOneJointSwingsNothing() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        var jointNode = 0
        let data = try TestSupport.modifiedSeedSanData(name: "one joint spring") { json in
            var extensions = json.object("extensions") ?? [:]
            var springBone = extensions.object("VRMC_springBone") ?? [:]
            let springs = springBone.objects("springs")
            let joints = springs.first?.objects("joints") ?? []
            guard let node = joints.first?.int("node") else {
                throw VRMError.dataInconsistent("Missing Seed-san spring bone fixture data")
            }
            jointNode = node
            springBone["springs"] = [["joints": [["node": .int(node)]]]]
            extensions["VRMC_springBone"] = .object(springBone)
            json["extensions"] = .object(extensions)
        }
        let vrmEntity = try await VRMEntityLoader(withData: data, shaders: []).loadEntity()
        let joint = try #require(vrmEntity.entity(forNodeAt: jointNode))
        let rotation = joint.transform.rotation

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(joint.transform.rotation == rotation)
    }
}
#endif
