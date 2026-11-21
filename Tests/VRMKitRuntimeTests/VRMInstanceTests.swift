import Foundation
import SIMDCompat
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMKitRuntime

/// A model built from an asset moves with no renderer: a reader hands back what moved, the
/// skins as posed, the morph weights and material values the expressions drive and how each
/// mesh shows.
@Suite
struct VRMInstanceTests {
    /// An asset is immutable, so the tests share one read per fixture and each builds its own instance.
    private static let seedSan = Task { try await GLTFAsset.load(vrm: try VRM(data: VRMSampleAsset.seedSan.data)) }
    private static let aliciaSolid = Task { try await GLTFAsset.load(vrm: try VRM(data: VRMSampleAsset.aliciaSolid.data)) }

    private func instance(_ asset: VRMSampleAsset) async throws -> VRMInstance {
        let read = try await (asset == .aliciaSolid ? Self.aliciaSolid : Self.seedSan).value
        return try VRMInstance(asset: read)
    }

    /// The first take carries everything, and one after nothing has moved carries nothing.
    @Test
    func testTheFirstTakeCarriesEverythingAndOneAfterNothing() async throws {
        let model = try await instance(.seedSan)
        var reader = model.makeOutputReader(solvesSkins: true)
        let first = reader.takeChanges()
        #expect(!first.skins.isEmpty)
        #expect(!first.morphWeights.isEmpty)
        #expect(!first.visibility.isEmpty)
        for skin in first.skins {
            #expect(skin.jointMatrices.count == model.asset.skins[skin.skinIndex].joints.count)
        }

        let still = reader.takeChanges()
        #expect(still.skins.isEmpty)
        #expect(still.morphWeights.isEmpty)
        #expect(still.visibility.isEmpty)
    }

    @Test
    func testAnExpressionMovesTheMorphWeightsOfTheMeshesItBinds() async throws {
        let model = try await instance(.seedSan)
        var reader = model.makeOutputReader(solvesSkins: true)
        _ = reader.takeChanges()
        let key = try #require(model.availableExpressions.first { $0.key == .preset(.aa) }?.key)
        model.setExpressions([key: 1])
        let output = reader.takeChanges()
        #expect(output.morphWeights.values.contains { $0.contains { $0 > 0 } })
        #expect(model.expression(for: key) == 1)
    }

    /// A bone an update handler poses moves its joint in the skins the update hands back.
    @Test
    func testABonePosedInAnUpdateHandlerMovesItsJoint() async throws {
        let model = try await instance(.seedSan)
        var reader = model.makeOutputReader(solvesSkins: true)
        let first = reader.takeChanges()
        let head = try #require(model.node(for: .head))
        model.setUpdateHandler({ _ in
            model.pose.setLocalRotation(simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0)), ofNode: head)
        }, at: .afterAnimation)
        model.update(deltaTime: 1 / 60)
        let output = reader.takeChanges()
        let skin = try #require(output.skins.first { model.asset.skins[$0.skinIndex].joints.contains(head) })
        let joint = try #require(model.asset.skins[skin.skinIndex].joints.firstIndex(of: head))
        let before = try #require(first.skins.first { $0.nodeIndex == skin.nodeIndex })
        #expect(skin.jointMatrices[joint] != before.jointMatrices[joint])
    }

    /// The first-person view cuts the head out of an `auto` mesh rather than hiding it.
    @Test
    func testTheFirstPersonViewCutsTheHeadOut() async throws {
        let model = try await instance(.aliciaSolid)
        var reader = model.makeOutputReader(solvesSkins: false)
        _ = reader.takeChanges()
        model.firstPersonRenderMode = .firstPerson
        let output = reader.takeChanges()
        #expect(output.visibility.values.contains(.firstPersonCut))
        model.firstPersonRenderMode = .firstPerson
        #expect(reader.takeChanges().visibility.isEmpty)
    }

    /// Without the cut, an `auto` mesh draws whole for a first-person camera too.
    @Test
    func testTheFirstPersonViewOfAnUnpreparedModelCutsNothing() async throws {
        let read = try await GLTFAsset.load(vrm: try VRM(data: VRMSampleAsset.aliciaSolid.data),
                                            preparesFirstPerson: false)
        let model = try VRMInstance(asset: read)
        var reader = model.makeOutputReader(solvesSkins: false)
        _ = reader.takeChanges()
        model.firstPersonRenderMode = .firstPerson
        let output = reader.takeChanges()
        #expect(!output.visibility.isEmpty)
        #expect(!output.visibility.values.contains(.firstPersonCut))
    }

    /// A `.vrma` retargets onto the humanoid of the instance it plays on.
    @Test
    func testAVRMAnimationRetargetsOntoTheHumanoid() async throws {
        let model = try await instance(.seedSan)
        let hips = try #require(model.node(for: .hips))
        let rest = model.pose.localTransform(ofNode: hips)
        let controller = try model.playAnimation(try VRMAnimation(withURL: VRMASampleAsset.walk.url), loops: true)
        model.update(deltaTime: controller.animation.duration / 3)
        let moved = model.pose.localTransform(ofNode: hips)
        #expect(moved.translation != rest.translation || moved.rotation != rest.rotation)
    }

    /// A snapshot stands as the instance stood, and moves on its own after.
    @Test
    func testASnapshotStandsAsTheInstanceStood() async throws {
        let model = try await instance(.seedSan)
        let head = try #require(model.node(for: .head))
        model.pose.setLocalRotation(simd_quatf(angle: 0.3, axis: SIMD3(1, 0, 0)), ofNode: head)
        model.setExpressions([.preset(.happy): 1])

        let copy = try model.snapshot()
        #expect(copy.pose.localTransform(ofNode: head) == model.pose.localTransform(ofNode: head))
        #expect(copy.expression(for: .preset(.happy)) == 1)

        copy.pose.setLocalRotation(simd_quatf(angle: -0.3, axis: SIMD3(1, 0, 0)), ofNode: head)
        #expect(copy.pose.localTransform(ofNode: head) != model.pose.localTransform(ofNode: head))
    }

    @Test
    func testAPlainGLTFMovesWithoutTheVRMLayers() async throws {
        let asset = try await GLTFAsset.load(document: try GLTFDocument(withURL: GLTFSampleAsset.simpleSkin.url))
        #expect(throws: VRMError.self) { try VRMInstance(asset: asset) }
        var reader = try GLTFInstance(asset: asset).makeOutputReader(solvesSkins: true)
        #expect(!reader.takeChanges().skins.isEmpty)
    }

    /// Readers follow one instance apart: what one takes, another still takes, and a change
    /// between frames hands the skins of the frame after to each reader that solves them.
    @Test
    func testReadersFollowOneInstanceApart() async throws {
        let model = try await instance(.seedSan)
        var first = model.makeOutputReader(solvesSkins: true)
        var second = model.makeOutputReader(solvesSkins: true)
        var unskinned = model.makeOutputReader(solvesSkins: false)
        _ = first.takeChanges()
        #expect(unskinned.takeChanges().skins.isEmpty)

        model.setExpressions([.preset(.aa): 1])
        let changed = first.takeChanges()
        #expect(!changed.morphWeights.isEmpty)
        #expect(changed.skins.isEmpty)
        #expect(!unskinned.takeChanges().morphWeights.isEmpty)

        let head = try #require(model.node(for: .head))
        model.pose.setLocalRotation(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)), ofNode: head)
        model.update(deltaTime: 1 / 60)
        #expect(!first.takeChanges().skins.isEmpty)
        #expect(first.takeChanges().skins.isEmpty)

        // The second reader has taken nothing yet, so it takes everything, the expression included.
        let late = second.takeChanges()
        #expect(!late.skins.isEmpty)
        #expect(late.morphWeights.values.contains { $0.contains(1) })
        #expect(Set(late.visibility.keys) == Set(model.asset.meshIndicesByNode.keys))
    }
}
