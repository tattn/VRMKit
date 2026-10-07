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
        for binding in vrmEntity.skinBindings {
            let modelEntity = binding.modelEntity
            let skeleton = binding.skeleton
            guard let jointTransforms = binding.deformedMesh?.jointTransforms,
                  jointTransforms.count == skeleton.joints.count else {
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
                #expect(jointTransforms[index].matrix.isApproximatelyEqual(to: expected, tolerance: 0.0005))
                checkedJoints += 1
            }
        }
        #expect(checkedJoints > 0)
    }

    /// A paused model keeps its springs in the shape they swung to, carried rigidly by the
    /// head they hang off however the head turns, and swings them again once resumed.
    @Test
    func testPausedSpringBonesKeepTheirShapeWhileTheModelMoves() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                            shaders: []).loadEntity()
        let head = try #require(vrmEntity.humanoid.node(for: .head))
        func turnHead(by angle: Float) {
            head.transform.rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0)) * head.transform.rotation
            vrmEntity.invalidateSkinPose(for: [head])
        }
        func localRotations() -> [simd_quatf] {
            var rotations: [simd_quatf] = []
            func visit(_ entity: Entity) {
                rotations.append(entity.transform.rotation)
                entity.children.forEach(visit)
            }
            head.children.forEach(visit)
            return rotations
        }
        turnHead(by: .pi / 4)
        for _ in 0..<10 { vrmEntity.update(deltaTime: 1.0 / 60.0) }

        vrmEntity.springBoneConfiguration.isPaused = true
        let held = localRotations()
        for _ in 0..<10 {
            turnHead(by: -.pi / 20)
            vrmEntity.update(deltaTime: 1.0 / 60.0)
        }
        #expect(localRotations() == held)

        vrmEntity.springBoneConfiguration.isPaused = false
        for _ in 0..<10 { vrmEntity.update(deltaTime: 1.0 / 60.0) }
        #expect(localRotations() != held)
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

    /// A model migrated from VRM 0.x can name a node in several springs. It loads, and
    /// the node swings with the first of them.
    @Test
    func testAModelNamingAJointInSeveralSpringsLoads() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "repeated spring") { json in
            var extensions = json.object("extensions") ?? [:]
            var springBone = extensions.object("VRMC_springBone") ?? [:]
            let springs = springBone.objects("springs")
            guard let first = springs.first else {
                throw VRMError.dataInconsistent("Missing Seed-san spring bone fixture data")
            }
            springBone["springs"] = .objects(springs + [first])
            extensions["VRMC_springBone"] = .object(springBone)
            json["extensions"] = .object(extensions)
        }
        let vrmEntity = try await VRMEntityLoader(withData: data, shaders: []).loadEntity()
        vrmEntity.update(deltaTime: 1.0 / 60.0)
    }
}
#endif
