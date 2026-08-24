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
    func testAutomaticUpdateIsOnByDefaultAndCanBeToggled() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try loader.loadEntity()
        #expect(vrmEntity.isAutomaticUpdateEnabled)

        vrmEntity.isAutomaticUpdateEnabled = false
        #expect(!vrmEntity.isAutomaticUpdateEnabled)

        vrmEntity.isAutomaticUpdateEnabled = true
        #expect(vrmEntity.isAutomaticUpdateEnabled)
    }

    @Test
    func testParentKeepsTheLoadedEntityAlive() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Adding the model to a scene is all its lifetime needs: nothing outside
        // the entity graph has to hold on to it for the system to keep animating.
        let parent = Entity()
        weak var loaded: VRMEntity?
        do {
            let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
            let vrmEntity = try loader.loadEntity()
            loaded = vrmEntity
            parent.addChild(vrmEntity)
        }

        #expect(loaded != nil)
        #expect(parent.children.first === loaded)
    }

    @Test
    func testClonedEntityIsInert() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // RealityKit builds clones through `init()`, so a clone is a copy of the
        // rendered hierarchy with no runtime behind it.
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try loader.loadEntity()
        let clone = vrmEntity.clone(recursive: true)

        #expect(vrmEntity.humanoid.node(for: .neck) != nil)
        #expect(clone.humanoid.node(for: .neck) == nil)
        // The system reaches the clone too, so updating it has to stay harmless.
        clone.update(deltaTime: 1.0 / 60.0)
    }

    /// A model with neither spring bones nor node constraints holds whatever
    /// pose it was last put in, so its per-frame update stops re-solving every
    /// skeleton. Posing a joint directly is what says otherwise.
    @Test
    func testAStaticModelSolvesItsSkinOnlyOnceInvalidated() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "no dynamics") { json in
            var extensions = json["extensions"] as? [String: Any] ?? [:]
            extensions.removeValue(forKey: "VRMC_springBone")
            json["extensions"] = extensions
            json["nodes"] = (json["nodes"] as? [[String: Any]] ?? []).map { node in
                var node = node
                if var nodeExtensions = node["extensions"] as? [String: Any] {
                    nodeExtensions.removeValue(forKey: "VRMC_node_constraint")
                    node["extensions"] = nodeExtensions
                }
                return node
            }
        }
        let vrmEntity = try VRMEntityLoader(withData: data, shaders: []).loadEntity()

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        let before = Self.jointRotations(of: vrmEntity)
        #expect(!before.isEmpty)

        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(Self.jointRotations(of: vrmEntity) == before)

        vrmEntity.invalidateSkinPose()
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        #expect(Self.jointRotations(of: vrmEntity) != before)
    }

    /// A model that does move its own joints keeps refreshing every frame, so
    /// the skip above cannot leave a spring-driven model a frame behind.
    @Test
    func testAModelWithSpringBonesStillRefreshesEveryFrame() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: []).loadEntity()

        let head = try #require(vrmEntity.humanoid.node(for: .head))
        let before = Self.jointRotations(of: vrmEntity)
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        vrmEntity.update(deltaTime: 1.0 / 60.0)

        #expect(Self.jointRotations(of: vrmEntity) != before)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func jointRotations(of entity: Entity) -> [SIMD4<Float>] {
        TestSupport.modelEntities(in: entity).flatMap { modelEntity in
            modelEntity.components[SkeletalPosesComponent.self]?.poses.default?
                .jointTransforms.map(\.rotation.vector) ?? []
        }
    }

    /// The VRM rides on the entity as a component, so a clone can still be asked
    /// what model it came from instead of trapping.
    @Test
    func testClonedEntityStillCarriesItsVRM() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try loader.loadEntity()
        let clone = vrmEntity.clone(recursive: true)

        guard case .v1 = clone.vrm else {
            Issue.record("The clone lost the VRM it was copied from")
            return
        }
    }
}
#endif
