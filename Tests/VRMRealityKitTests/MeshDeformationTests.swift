#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// The skinning and morphing the loader runs on the GPU into each entity's `LowLevelMesh`.
@Suite
@MainActor
struct MeshDeformationTests {
    /// The entities drawing one glTF mesh, such as its model and its outline pass, are
    /// deformed by one dispatch, and every one of them draws the posed vertices. Without MToon
    /// there is no outline pass, so no mesh is drawn by more than one entity.
    @Test
    func testEveryEntityDrawingAMeshDrawsItPosed() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), TestSupport.isMToonRenderingAvailable else { return }
        let entity = try await TestSupport.sharedLoader(.seedSan).loadEntity()
        let siblings = try #require(Dictionary(grouping: entity.deformedMeshes) { ObjectIdentifier($0.source) }
            .values
            .first { $0.count > 1 && $0[0].source.skin != nil })
        // A mesh drawn from a pooled LowLevelMesh can have room past its own vertices.
        func vertices(of mesh: GLTFDeformedMesh) -> [UInt8] {
            var bytes: [UInt8] = []
            mesh.lowLevelMesh.withUnsafeBytes(bufferIndex: 0) {
                bytes = Array($0.prefix(mesh.geometry.vertexCount * GLTFDeformedVertex.stride))
            }
            return bytes
        }
        let rest = vertices(of: siblings[0])

        entity.humanoid.node(for: .hips)?.transform.rotation *= simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        entity.invalidateSkinPose()
        entity.flushDeformation()
        try waitForDeformation()

        let posed = vertices(of: siblings[0])
        #expect(posed != rest)
        for mesh in siblings.dropFirst() {
            #expect(vertices(of: mesh) == posed)
        }
    }

    /// Waits for the deformation submitted so far.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func waitForDeformation() throws {
        // The deformation queue runs its command buffers in order.
        let commandBuffer = try #require(try GLTFDeformationContext.shared().commandQueue.makeCommandBuffer())
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
#endif
