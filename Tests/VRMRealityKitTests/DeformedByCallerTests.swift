#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// An app that skins and morphs the vertices itself reads what to deform with from
/// ``GLTFEntity/meshDeformations``, and VRMKit stops writing them meanwhile.
@Suite
@MainActor
struct DeformedByCallerTests {
    /// The inputs give the vertices VRMKit writes itself.
    @Test
    func testTheInputsDeformTheVerticesAsVRMKitDoes() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        pose(entity)
        entity.flushDeformation()
        try waitForDeformation()

        let deformations = entity.meshDeformations.filter(\.isDeformable)
        try #require(deformations.contains { $0.jointCount > 0 })
        try #require(deformations.contains { $0.blendShapeWeights.contains { $0 != 0 } })
        for deformation in deformations {
            let mesh = try #require(entity.deformedMeshes.first { ObjectIdentifier($0.source) == deformation.id })
            let written = positions(of: mesh)
            let expected = Self.deform(deformation)
            let error = zip(written, expected).map { simd_length($0 - $1) }.max() ?? 0
            #expect(error < 1e-4, "mesh \(deformation.id): \(error)")
        }
    }

    /// Every material and pass drawing one glTF mesh has the same deformation, and the meshes
    /// list each glTF mesh once.
    @Test
    func testEveryPassOfAMeshHasOneDeformation() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), TestSupport.isMToonRenderingAvailable else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let geometry = entity.geometry(ofMaterial: 0)
        let body = try #require(geometry.first { $0.passName == nil })
        let outline = try #require(geometry.first { $0.passName == MToonShader.outlinePassName })
        #expect(body.deformation.id == outline.deformation.id)
        let ids = entity.meshDeformations.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(body.deformation.id))
    }

    /// While the caller deforms, VRMKit writes nothing and the revision moves; handing the
    /// meshes back writes them on the next update, and a snapshot is written either way.
    @Test
    func testVRMKitWritesNothingWhileTheCallerDeforms() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let deformation = try #require(entity.meshDeformations.first { $0.jointCount > 0 })
        let mesh = try #require(entity.deformedMeshes.first { ObjectIdentifier($0.source) == deformation.id })
        // The load submits the first pose
        try waitForDeformation()
        let rest = positions(of: mesh)
        let revision = deformation.revision

        entity.isDeformedByCaller = true
        pose(entity)
        entity.flushDeformation()
        try waitForDeformation()
        #expect(deformation.revision != revision)
        #expect(positions(of: mesh) == rest)

        let copy = entity.snapshot()
        try waitForDeformation()
        let copied = try #require(copy.modelEntitiesInHierarchy.lazy.compactMap(\.deformedMesh)
            .first { ObjectIdentifier($0.source) == deformation.id })
        #expect(positions(of: copied) != rest)

        entity.isDeformedByCaller = false
        pose(entity)
        entity.flushDeformation()
        try waitForDeformation()
        let expected = Self.deform(deformation)
        let error = zip(positions(of: mesh), expected).map { simd_length($0 - $1) }.max() ?? 0
        #expect(error < 1e-4)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func pose(_ entity: VRMEntity) {
        entity.humanoid.node(for: .hips)?.transform.rotation *= simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        entity.humanoid.node(for: .leftUpperArm)?.transform.rotation *= simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 0, 1))
        entity.invalidateSkinPose()
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

    /// The vertex positions the deformation's description gives, worked out on the CPU.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func deform(_ deformation: GLTFMeshDeformation) -> [SIMD3<Float>] {
        let geometry = deformation.geometry
        var matrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: deformation.jointCount)
        matrices.withUnsafeMutableBufferPointer { deformation.writeJointMatrices(into: $0) }
        let weights = deformation.blendShapeWeights
        let deltas = weights.indices.map { weights[$0] == 0 ? [] : geometry.blendShapeOffsets(forTarget: $0) }
        return (0..<geometry.vertexCount).map { vertex in
            var position = geometry.positions[vertex]
            for (target, weight) in weights.enumerated() where weight != 0 {
                position += weight * deltas[target][vertex]
            }
            guard geometry.isSkinned else { return position }
            let joints = geometry.jointIndices[vertex]
            let jointWeights = geometry.jointWeights[vertex]
            guard jointWeights.sum() > 0 else { return position }
            var skin = simd_float4x4()
            for lane in 0..<4 {
                skin += matrices[Int(joints[lane])] * jointWeights[lane]
            }
            let skinned = skin * SIMD4(position, 1)
            return SIMD3(skinned.x, skinned.y, skinned.z)
        }
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
