#if canImport(RealityKit)
import Foundation
import RealityKit
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
