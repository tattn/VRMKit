#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMKitRuntime
import VRMTestSupport
@testable import VRMRealityKit

/// An app drawing a model itself from the instance a ``GLTFEntity`` holds: it reads the vertex
/// data from the asset and what moves through a reader of its own, while the entity draws from
/// its own reader.
@Suite
@MainActor
struct InstanceOutputTests {
    /// An app's reader takes what the entity draws, the expressions set between updates included,
    /// and the skins only with the frame that moves the pose.
    @Test
    func testAnAppReaderTakesWhatTheEntityDraws() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.seedSan).loadEntity()
        let instance = try #require(entity.instance)
        var reader = instance.makeOutputReader(solvesSkins: true)
        let first = reader.takeChanges()
        #expect(!first.skins.isEmpty)
        #expect(!first.visibility.isEmpty)

        entity.setExpressions([.preset(.aa): 1])
        let morphed = reader.takeChanges()
        #expect(morphed.morphWeights.values.contains { $0.contains(1) })
        #expect(morphed.skins.isEmpty)

        let head = try #require(entity.humanoid.node(for: .head).flatMap(entity.nodeIndex(of:)))
        entity.pose?.setLocalRotation(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)), ofNode: head)
        entity.update(deltaTime: 1.0 / 60)
        #expect(!reader.takeChanges().skins.isEmpty)
        #expect(reader.takeChanges().skins.isEmpty)
    }

    /// An expression set on the instance between frames reaches the entity's meshes before any
    /// update, as it reaches an app's reader.
    @Test
    func testAChangeBetweenFramesReachesTheEntity() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.seedSan).loadEntity()
        let instance = try #require(entity.instance as? VRMInstance)
        let node = try #require(entity.morphBindings.keys.first { instance.morphWeights(ofNode: $0) != nil })
        let mesh = try #require(entity.morphBindings[node]?.modelEntities.first?.deformedMesh)

        instance.setExpressions([.preset(.aa): 1])
        #expect(mesh.blendShapeWeights == instance.morphWeights(ofNode: node))
    }

    /// The entity skinning from the pose and an app's reader solving the skins follow one pose
    /// apart: neither takes the other's moves.
    @Test
    func testAReaderAndTheEntitySkinningFollowThePoseApart() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.seedSan).loadEntity()
        let instance = try #require(entity.instance)
        let mesh = try #require(entity.deformedMeshes.first { $0.source.skin != nil })
        var reader = instance.makeOutputReader(solvesSkins: true)
        _ = reader.takeChanges()
        let head = try #require(entity.humanoid.node(for: .head).flatMap(entity.nodeIndex(of:)))

        instance.pose.setLocalRotation(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)), ofNode: head)
        var solved = mesh.jointTransforms
        entity.flushDeformation()
        #expect(mesh.jointTransforms != solved)
        #expect(!reader.takeChanges().skins.isEmpty)

        instance.pose.setLocalRotation(simd_quatf(angle: -0.3, axis: SIMD3(0, 1, 0)), ofNode: head)
        #expect(!reader.takeChanges().skins.isEmpty)
        solved = mesh.jointTransforms
        entity.flushDeformation()
        #expect(mesh.jointTransforms != solved)
    }

    /// While deformation is suspended nothing is solved or written; a snapshot is written either
    /// way, and resuming writes what moved meanwhile.
    @Test
    func testASuspendedEntityDeformsNothingUntilResumed() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.sharedLoader(.seedSan).loadEntity()
        let mesh = try #require(entity.deformedMeshes.first { $0.source.skin != nil })
        try waitForDeformation()
        let rest = positions(of: mesh)

        entity.isDeformationSuspended = true
        pose(entity)
        entity.update(deltaTime: 1.0 / 60)
        try waitForDeformation()
        #expect(positions(of: mesh) == rest)

        let copy = entity.snapshot()
        try waitForDeformation()
        let copied = try #require(copy.modelEntitiesInHierarchy.lazy.compactMap(\.deformedMesh)
            .first { $0.source === mesh.source })
        #expect(positions(of: copied) != rest)

        let hips = try #require(entity.humanoid.node(for: .hips).flatMap(entity.nodeIndex(of:)))
        entity.pose?.setLocalTranslation(SIMD3(0, 0.2, 0), ofNode: hips)
        entity.isDeformationSuspended = false
        entity.updateSkinPose()
        try waitForDeformation()
        #expect(positions(of: mesh) != positions(of: copied))
        #expect(positions(of: mesh) != rest)
    }

    /// A plain glTF entity holds an instance too, which its animations play on.
    @Test
    func testAGLTFEntityAnimatesThroughItsInstance() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.animatedMorphCube)
        let instance = try #require(entity.instance)
        var reader = instance.makeOutputReader(solvesSkins: false)
        _ = reader.takeChanges()
        try entity.playAnimation(at: 0, loops: true)
        entity.updateAnimations(deltaTime: 0.5)
        #expect(!reader.takeChanges().morphWeights.isEmpty)
        #expect(instance.animationPlayer.isPlaying)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func pose(_ entity: VRMEntity) {
        guard let pose = entity.pose else { return }
        for (bone, angle) in [(HumanoidBone.hips, Float(0.5)), (.leftUpperArm, 0.7)] {
            guard let node = entity.humanoid.node(for: bone).flatMap(entity.nodeIndex(of:)) else { continue }
            pose.setLocalRotation(pose.localTransform(ofNode: node).rotation * simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)),
                                  ofNode: node)
        }
        entity.setExpressions([.preset(.happy): 0.8, .preset(.aa): 0.5])
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func positions(of mesh: GLTFDeformedMesh) -> [SIMD3<Float>] {
        var positions: [SIMD3<Float>] = []
        mesh.lowLevelMesh.withUnsafeBytes(bufferIndex: 0) { raw in
            for index in 0..<mesh.geometry.vertexCount {
                let floats = raw.baseAddress!.advanced(by: index * GLTFDeformedVertex.stride).assumingMemoryBound(to: Float.self)
                positions.append(SIMD3(floats[0], floats[1], floats[2]))
            }
        }
        return positions
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func waitForDeformation() throws {
        // The deformation queue runs its command buffers in order.
        let commandBuffer = try #require(try GLTFDeformationContext.shared().commandQueue.makeCommandBuffer())
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
#endif
