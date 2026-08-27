#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What composed content does once it is loaded: a merged animation plays, and a written
/// spring bone chain swings. The writing side is checked in `VRMKitTests`.
@Suite
@MainActor
struct VRMCompositionMotionTests {
    /// A merged prop brings its animation with it, and the avatar's entity plays it
    /// through the API every glTF scene has.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testAnAnimationMergedIntoAVRMPlaysOnIt(model: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let composed = try ComposedModel(model: model)
        let entity = try await composed.loadEntity()
        let propeller = try #require(entity.entity(forNodeAt: composed.animatedNode))

        #expect(entity.animations.count == 1)
        let controller = try entity.playAnimation(at: 0)
        // AnimatedTriangle turns a quarter circle around +z by t = 0.25.
        entity.updateAnimations(deltaTime: 0.25)

        #expect(controller.time.isApproximatelyEqual(to: 0.25))
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        #expect(abs(simd_dot(propeller.transform.rotation, quarter)) > 0.999)
    }

    @Test
    func testAMergedAnimationAndTheVRMUpdateDoNotDisturbEachOther() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let composed = try ComposedModel(model: .seedSan)
        let entity = try await composed.loadEntity()
        let propeller = try #require(entity.entity(forNodeAt: composed.animatedNode))
        let head = try #require(entity.humanoid.node(for: .head))

        try entity.playAnimation(at: 0)
        entity.updateAnimations(deltaTime: 0.25)
        let animated = propeller.transform.rotation
        head.transform.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        let joints = TestSupport.jointRotations(in: entity)
        entity.update(deltaTime: 1.0 / 60.0)

        #expect(TestSupport.jointRotations(in: entity) != joints)
        #expect(abs(simd_dot(propeller.transform.rotation, animated)) > 0.999)
    }

    /// A written chain is one the loader reads and the spring runtime drives: moving what
    /// it hangs off swings it, in either version's spelling.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testAnAddedSpringBoneChainSwingsTheNodesItNames(model: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let composed = try ComposedModel(model: model, springBoneChain: true)
        let entity = try await composed.loadEntity()
        let ornament = try composed.ornament.map { try #require(entity.entity(forNodeAt: $0)) }
        let head = try #require(entity.humanoid.node(for: .head))

        // The first frame settles the chain, so what follows is the swing.
        entity.update(deltaTime: 1.0 / 60.0)
        #expect(ornament.allSatisfy { $0.transform.rotation.isApproximatelyIdentity })
        head.transform.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        var swung = false
        for _ in 0..<10 {
            entity.update(deltaTime: 1.0 / 60.0)
            swung = swung || ornament.contains { !$0.transform.rotation.isApproximatelyIdentity }
        }

        #expect(swung)
        // The last node is the difference the one API cannot hide: 1.0 reads it as a tail
        // and writes nothing to it, while 0.x swings every node below the root.
        let tailSwings = try #require(ornament.last).transform.rotation.isApproximatelyIdentity == false
        #expect(tailSwings == composed.isVRM0)
    }

    /// Without a chain the same nodes hang rigidly, which says the swing above came
    /// from the chain.
    @Test
    func testMergedNodesWithoutAChainDoNotSwing() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let composed = try ComposedModel(model: .seedSan)
        let entity = try await composed.loadEntity()
        let ornament = try composed.ornament.map { try #require(entity.entity(forNodeAt: $0)) }
        let head = try #require(entity.humanoid.node(for: .head))

        head.transform.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        for _ in 0..<10 {
            entity.update(deltaTime: 1.0 / 60.0)
        }

        #expect(ornament.allSatisfy { $0.transform.rotation.isApproximatelyIdentity })
    }
}

// MARK: - Fixtures

/// An avatar with content composed onto it, as an application saving a merged model
/// would write it: an animated prop under a hand, and a line of fresh nodes off the
/// head, with or without the chain that swings them.
@MainActor
private struct ComposedModel {
    let data: Data
    /// Where the merged prop's animated node landed.
    let animatedNode: Int
    /// The line of nodes hanging off the head.
    let ornament: [Int]
    /// The two versions swing a chain's last node differently.
    let isVRM0: Bool

    init(model: VRMSampleAsset, springBoneChain: Bool = false) throws {
        // Parsed once and handed to both: the editable document copies the JSON it edits.
        let vrm = try VRM(document: try GLTFDocument(data: model.data))
        var document = try GLTFEditableDocument(document: vrm.document)
        let head = GLTFNodeIndex(try #require(vrm.nodeIndex(of: .head)))
        isVRM0 = { if case .v0 = vrm { true } else { false } }()

        animatedNode = vrm.document.gltf.nodes.count
        try document.append(try GLTFDocument(withURL: GLTFSampleAsset.animatedTriangle.url),
                            under: GLTFNodeIndex(try #require(vrm.nodeIndex(of: .leftHand))),
                            name: "prop")

        let ornament = try document.addOrnamentChain(under: head)
        self.ornament = ornament.map(\.rawValue)
        if springBoneChain {
            if isVRM0 {
                try document.addVRM0SpringBone(VRM0SpringBoneGroup(rootBones: [ornament[0]],
                                                                   stiffness: 0.5,
                                                                   dragForce: 0.2,
                                                                   comment: "charm"))
            } else {
                try document.addVRM1SpringBone(VRM1Spring(joints: ornament,
                                                          stiffness: 0.5,
                                                          dragForce: 0.2,
                                                          name: "charm"))
            }
        }
        data = try document.serialize()
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func loadEntity() async throws -> VRMEntity {
        try await VRMEntityLoader(withData: data, shaders: []).loadEntity()
    }
}

private extension simd_quatf {
    /// Whether the node still sits where it was authored.
    var isApproximatelyIdentity: Bool {
        abs(simd_dot(self, quat_identity_float)) > 0.9999
    }
}
#endif
