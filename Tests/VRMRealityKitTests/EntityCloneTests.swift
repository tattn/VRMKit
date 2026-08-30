#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What `Entity.clone(recursive:)` copies. RealityKit builds a clone through
/// `init()`, so it renders what the original rendered and carries none of the
/// runtime behind it: every API that would drive the model has to say so rather
/// than silently doing nothing.
@Suite
@MainActor
struct EntityCloneTests {
    /// A clone reads its metadata off the document it carries, and refuses the
    /// playback that metadata describes.
    @Test
    func testACloneOfAGLTFEntityCannotBeAnimated() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.animatedTriangle)
        let clone = entity.clone(recursive: true)

        #expect(entity.hasRuntimeBindings)
        #expect(!clone.hasRuntimeBindings)
        #expect(clone.animations.count == entity.animations.count)
        #expect(throws: VRMError.self) { try clone.playAnimation(at: 0) }
    }

    /// The VRM rides on the entity as a component, so a clone can still be asked
    /// what model it came from instead of trapping. Nothing that drives that
    /// model comes with it.
    @Test
    func testACloneOfAVRMEntityIsInertButKeepsItsVRM() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let clone = vrmEntity.clone(recursive: true)

        guard case .v1 = clone.vrm else {
            Issue.record("The clone lost the VRM it was copied from")
            return
        }
        #expect(vrmEntity.humanoid.node(for: .neck) != nil)
        #expect(clone.humanoid.node(for: .neck) == nil)
        // Material indices scope the runtime material setters, so a clone answers
        // none rather than indices those setters could not act on.
        #expect(!vrmEntity.materialIndices(under: vrmEntity).isEmpty)
        #expect(clone.materialIndices(under: clone).isEmpty)
        #expect(vrmEntity.materialIndices(under: clone).isEmpty)
        #expect(throws: VRMError.self) {
            try clone.playAnimation(try VRMAnimation(data: VRMASampleFixture.standard()))
        }
        // The update system reaches the clone too, so updating it has to stay harmless.
        clone.update(deltaTime: 1.0 / 60.0)
    }
}
#endif
