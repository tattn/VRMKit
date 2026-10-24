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
/// data from the asset and follows the outputs the entity draws, while the entity keeps its
/// RealityKit meshes still.
@Suite
@MainActor
struct InstanceOutputTests {
    /// The handler is given every output the entity draws, the expressions set between updates
    /// included.
    @Test
    func testTheOutputHandlerSeesWhatTheEntityDraws() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        var outputs: [GLTFFrameOutput] = []
        entity.setOutputHandler { outputs.append($0) }
        entity.instance?.outputsSkins = true

        // The skins come with the frame, not with a value set between frames.
        entity.setExpressions([.preset(.aa): 1])
        let morphed = try #require(outputs.last)
        #expect(morphed.morphWeights.values.contains { $0.contains(1) })
        #expect(morphed.skins.isEmpty)

        let head = try #require(entity.humanoid.node(for: .head).flatMap(entity.nodeIndex(of:)))
        entity.pose?.setLocalRotation(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)), ofNode: head)
        entity.update(deltaTime: 1.0 / 60)
        #expect(outputs.count == 2)
        #expect(outputs.last?.skins.isEmpty == false)

        entity.setOutputHandler(nil)
        entity.setExpressions([.preset(.aa): 0])
        #expect(outputs.count == 2)
    }

    /// The current output holds all of what the instance draws with, and leaves what the next
    /// output hands back as it was.
    @Test
    func testTheCurrentOutputHoldsEverything() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let instance = try #require(entity.instance)
        let asset = instance.asset
        entity.setExpressions([.preset(.happy): 1])
        instance.outputsSkins = true
        _ = instance.takeOutput()
        let head = try #require(entity.humanoid.node(for: .head).flatMap(entity.nodeIndex(of:)))
        instance.pose.setLocalRotation(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)), ofNode: head)

        let current = instance.currentOutput()
        let skinnedNodes = asset.meshIndicesByNode.filter { asset.meshes[$0.value].skinIndex != nil }.keys
        let morphedNodes = asset.meshIndicesByNode.filter { asset.meshes[$0.value].geometry.blendShapeTargetCount > 0 }.keys
        #expect(Set(current.skins.map(\.nodeIndex)) == Set(skinnedNodes))
        #expect(Set(current.morphWeights.keys) == Set(morphedNodes))
        #expect(Set(current.visibility.keys) == Set(asset.meshIndicesByNode.keys))
        #expect(current.morphWeights.values.contains { $0.contains(1) })

        // The head moved after the last output, which the next one still hands back.
        #expect(!instance.takeOutput().skins.isEmpty)
    }

    /// An instance handing out its skins and the entity skinning from the pose follow one pose
    /// apart: neither takes the other's moves.
    @Test
    func testTheSkinOutputAndTheEntitySkinningFollowThePoseApart() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let instance = try #require(entity.instance)
        let deformation = try #require(entity.meshDeformations.first { $0.jointCount > 0 })
        instance.outputsSkins = true
        _ = instance.takeOutput()
        let head = try #require(entity.humanoid.node(for: .head).flatMap(entity.nodeIndex(of:)))

        instance.pose.setLocalRotation(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)), ofNode: head)
        var revision = deformation.revision
        entity.flushDeformation()
        #expect(deformation.revision != revision)
        #expect(!instance.takeOutput().skins.isEmpty)

        instance.pose.setLocalRotation(simd_quatf(angle: -0.3, axis: SIMD3(0, 1, 0)), ofNode: head)
        #expect(!instance.takeOutput().skins.isEmpty)
        revision = deformation.revision
        entity.flushDeformation()
        #expect(deformation.revision != revision)
    }

    /// While deformation is suspended nothing is solved or written; a snapshot is written either
    /// way, and resuming writes what moved meanwhile.
    @Test
    func testASuspendedEntityDeformsNothingUntilResumed() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let deformation = try #require(entity.meshDeformations.first { $0.jointCount > 0 })
        let mesh = try #require(entity.deformedMeshes.first { ObjectIdentifier($0.source) == deformation.id })
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
            .first { ObjectIdentifier($0.source) == deformation.id })
        #expect(positions(of: copied) != rest)

        let hips = try #require(entity.humanoid.node(for: .hips).flatMap(entity.nodeIndex(of:)))
        entity.pose?.setLocalTranslation(SIMD3(0, 0.2, 0), ofNode: hips)
        entity.isDeformationSuspended = false
        entity.updateSkinPose()
        try waitForDeformation()
        #expect(positions(of: mesh) != positions(of: copied))
        #expect(positions(of: mesh) != rest)
    }

    /// The geometry a material draws names the node and slot of the instance's asset it draws,
    /// on a snapshot too.
    @Test
    func testTheMaterialGeometryNamesTheAssetSlot() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let asset = try #require(entity.instance?.asset)
        let copy = entity.snapshot()
        var compared = 0
        for material in entity.gltf.materials.indices {
            let geometries = entity.geometry(ofMaterial: material)
            for geometry in geometries {
                let mesh = try #require(asset.mesh(drawnByNode: geometry.nodeIndex))
                #expect(mesh.materialIndices[geometry.slotIndex] == material)
                #expect(mesh.geometry.slots[geometry.slotIndex].indexRange == geometry.indexRange)
                compared += 1
            }
            // A snapshot lists the places a material draws in an order of its own.
            func places(_ geometries: [GLTFMaterialGeometry]) -> [SIMD2<Int>] {
                geometries.map { SIMD2($0.nodeIndex, $0.slotIndex) }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
            }
            #expect(places(copy.geometry(ofMaterial: material)) == places(geometries))
        }
        #expect(compared > 0)
    }

    /// A plain glTF entity holds an instance too, which its animations play on.
    @Test
    func testAGLTFEntityAnimatesThroughItsInstance() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.animatedMorphCube)
        let instance = try #require(entity.instance)
        var outputs: [GLTFFrameOutput] = []
        entity.setOutputHandler { outputs.append($0) }
        try entity.playAnimation(at: 0, loops: true)
        entity.updateAnimations(deltaTime: 0.5)
        #expect(outputs.contains { !$0.morphWeights.isEmpty })
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
        let fence = try GLTFEntity.deformationFence()
        let commandBuffer = try #require(fence.device.makeCommandQueue()?.makeCommandBuffer())
        fence.wait(in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
#endif
