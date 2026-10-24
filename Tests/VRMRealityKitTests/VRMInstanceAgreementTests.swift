#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMKitRuntime
import VRMTestSupport
@testable import VRMRealityKit

/// A ``VRMInstance`` drawn by another renderer skins its meshes as RealityKit does: the same
/// joint matrices for every skinned mesh, at rest and posed.
@Suite
@MainActor
struct VRMInstanceAgreementTests {
    @Test(arguments: VRMSampleAsset.allCases)
    func testTheInstanceSkinsAsTheEntityDoes(asset: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrm = try VRM(data: asset.data)
        let entity = try await VRMEntityLoader(vrm: vrm, shaders: []).loadEntity()
        let instance = try VRMInstance(asset: try await GLTFAsset.load(vrm: vrm))

        // The same pose on both, away from rest.
        let entityPose = try #require(entity.pose)
        let head = try #require(instance.node(for: .head))
        let turn = simd_quatf(angle: 0.4, axis: SIMD3(0, 1, 0))
        entityPose.setLocalRotation(turn, ofNode: head)
        instance.pose.setLocalRotation(turn, ofNode: head)
        entity.flushDeformation()

        let instanceSkins = Dictionary(uniqueKeysWithValues: instance.takeOutput().skins.map { ($0.nodeIndex, $0) })
        var compared = 0
        for modelEntity in entity.modelEntitiesInHierarchy {
            guard let mesh = modelEntity.deformedMesh, let skeleton = mesh.source.skin?.skeleton,
                  let node = nodeIndex(above: modelEntity) else { continue }
            let skin = try #require(instanceSkins[node])
            var matrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: skeleton.joints.count)
            matrices.withUnsafeMutableBufferPointer { mesh.writeJointMatrices(into: $0.baseAddress!) }
            #expect(matrices.count == skin.jointMatrices.count)
            for (expected, actual) in zip(matrices, skin.jointMatrices) {
                for (lhs, rhs) in [(expected.columns.0, actual.columns.0), (expected.columns.1, actual.columns.1),
                                   (expected.columns.2, actual.columns.2), (expected.columns.3, actual.columns.3)] {
                    #expect(simd_length(lhs - rhs) < 1e-3)
                }
            }
            compared += 1
        }
        #expect(compared > 0)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func nodeIndex(above entity: Entity) -> Int? {
        var current = entity.parent
        while let ancestor = current {
            if let node = ancestor.components[GLTFNodeComponent.self]?.nodeIndex { return node }
            current = ancestor.parent
        }
        return nil
    }
}
#endif
