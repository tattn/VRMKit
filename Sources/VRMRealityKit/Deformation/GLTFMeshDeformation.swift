#if canImport(RealityKit)
import Foundation
import simd
import VRMKitRuntime

/// What one glTF mesh of a ``GLTFEntity`` is skinned and morphed with, for a caller that
/// deforms the vertices itself (``GLTFEntity/isDeformedByCaller``). Every material and render
/// pass drawing the mesh reads the same deformation.
///
/// A vertex at rest is ``geometry``'s, plus each morph target's delta
/// (``GLTFMeshGeometry/blendShapeOffsets(forTarget:)``) times its weight (``blendShapeWeights``),
/// then skinned by the joints and weights of ``GLTFMeshGeometry/jointIndices`` and
/// ``GLTFMeshGeometry/jointWeights`` with the matrices ``writeJointMatrices(into:)`` writes.
/// The result is in the space of the model entity drawing the mesh.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public struct GLTFMeshDeformation {
    let mesh: GLTFDeformedMesh

    /// The same for every material and pass drawing the mesh, across frames.
    public var id: ObjectIdentifier { ObjectIdentifier(mesh.source) }

    public var geometry: GLTFMeshGeometry { mesh.geometry }

    /// Whether anything moves the vertices: the vertices of a mesh that is neither skinned nor
    /// morphed stay at rest.
    public var isDeformable: Bool { mesh.source.isDeformable }

    /// One weight per morph target, whose POSITION deltas ``GLTFMeshGeometry/blendShapeOffsets(forTarget:)`` gives.
    public var blendShapeWeights: [Float] { mesh.blendShapeWeights }

    /// How many matrices ``writeJointMatrices(into:)`` writes: one per joint
    /// ``GLTFMeshGeometry/jointIndices`` refers to. Zero for a mesh that is not skinned.
    public var jointCount: Int { mesh.source.skin?.skeleton.joints.count ?? 0 }

    /// Writes each joint's skinning matrix, its pose in the model's space times its inverse
    /// bind matrix, as the last update solved it. Identity before the first solve.
    public func writeJointMatrices(into matrices: UnsafeMutableBufferPointer<simd_float4x4>) {
        guard let base = matrices.baseAddress, matrices.count >= jointCount else { return }
        mesh.writeJointMatrices(into: base)
    }

    /// Moves whenever the pose or the weights the vertices are deformed with change, so a mesh
    /// whose revision stands needs no new deformation.
    public var revision: UInt64 { mesh.inputRevision }
}
#endif
