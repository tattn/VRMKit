#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// ``GLTFEntity/materialIndices(under:)``, the query that scopes the runtime
/// material APIs to part of a model.
@Suite
@MainActor
struct MaterialIndicesTests {

    /// The whole graph answers with every rendered material, and a node's
    /// subtree with exactly the materials its own model entities carry.
    @Test
    func testMaterialIndicesFollowTheModelEntitiesUnderTheRoot() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let allRendered = Set(TestSupport.materialIndexes(in: entity))
        #expect(!allRendered.isEmpty)
        #expect(entity.materialIndices(under: entity) == allRendered)

        // Seed-san node 1 is "hair_tail", whose mesh draws material 0 alone;
        // node 0 is "hair", whose mesh draws materials 0 and 1.
        let hairTail = try #require(entity.entity(forNodeAt: 1))
        #expect(entity.materialIndices(under: hairTail) == [0])
        let hair = try #require(entity.entity(forNodeAt: 0))
        #expect(entity.materialIndices(under: hair) == [0, 1])
    }

    /// Indices point into one document, so an entity loaded from another one
    /// never leaks its own into the answer, however the graphs are parented.
    @Test
    func testEntitiesOfAnotherDocumentAreNotCounted() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let avatar = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let attached = try await TestSupport.loadEntity(.simpleTexture)
        let avatarMaterials = avatar.materialIndices(under: avatar)
        #expect(attached.materialIndices(under: attached) == [0])

        let head = try #require(avatar.entity(forNodeAt: 2))
        head.addChild(attached)
        #expect(avatar.materialIndices(under: attached).isEmpty)
        #expect(avatar.materialIndices(under: head) == [2, 3, 4])
        #expect(avatar.materialIndices(under: avatar) == avatarMaterials)
        // The attached document answers for itself, wherever it hangs.
        #expect(attached.materialIndices(under: attached) == [0])
    }

    /// A recursive clone renders, but carries no material runtime, so it
    /// answers empty rather than indices the runtime setters could not act on.
    @Test
    func testACloneAnswersEmpty() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.simpleTexture)
        #expect(entity.materialIndices(under: entity) == [0])

        let clone = entity.clone(recursive: true)
        #expect(clone.materialIndices(under: clone).isEmpty)
        #expect(entity.materialIndices(under: clone).isEmpty)
    }
}
#endif
