#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import VRMKit

/// What every instance of one merged mesh deforms from: the rest-pose attributes,
/// the joint influences and the morph deltas, once on the GPU per document, and
/// the layout of the `LowLevelMesh` each instance draws.
///
/// Built once per mesh template and shared by every entity cloned from it, across
/// loads of the document.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class GLTFMeshSource {
    let geometry: GLTFMeshGeometry
    let context: GLTFDeformationContext
    let descriptor: LowLevelMesh.Descriptor

    let basePositions: MTLBuffer
    let baseNormals: MTLBuffer?
    let baseTangents: MTLBuffer?
    let baseBitangents: MTLBuffer?
    /// Per vertex, x is 1 where the rest tangent, bitangent and normal make a right-handed
    /// frame and -1 where they make a left-handed one (mirrored UVs), drawn as uv1 from
    /// ``tangentHandednessBufferIndex``. RealityKit hands a surface shader the tangent of a
    /// right-handed frame, turning it over where the frame is left-handed, so MToon turns it
    /// back by this sign as glTF's tangent `w` would. Empty for a mesh without tangents.
    let tangentHandedness: [SIMD2<Float>]
    let tangentHandednessBufferIndex: Int?

    struct Skin {
        let joints: MTLBuffer
        let weights: MTLBuffer
        /// The joints in the order the influences index them, parents first.
        let skeleton: MeshResource.Skeleton
    }

    let skin: Skin?

    /// Whether anything moves the vertices: a static mesh is written once and never
    /// dispatched.
    var isDeformable: Bool { skin != nil || geometry.hasBlendShapes }

    /// The layout index of the buffer holding the texture coordinates, when the mesh has any.
    static let texcoordBufferIndex = 1

    init(geometry: GLTFMeshGeometry, skeleton: MeshResource.Skeleton?, context: GLTFDeformationContext) throws {
        self.geometry = geometry
        self.context = context
        guard let basePositions = context.makePackedBuffer(geometry.positions) else {
            throw VRMError._dataInconsistent("a mesh with no vertices cannot be drawn")
        }
        self.basePositions = basePositions
        baseNormals = context.makePackedBuffer(geometry.normals)
        baseTangents = context.makePackedBuffer(geometry.tangents)
        baseBitangents = context.makePackedBuffer(geometry.bitangents)
        if let skeleton, geometry.isSkinned,
           let joints = context.device.makeBuffer(geometry.jointIndices),
           let weights = context.device.makeBuffer(geometry.jointWeights) {
            skin = Skin(joints: joints, weights: weights, skeleton: skeleton)
        } else {
            skin = nil
        }

        var attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: GLTFDeformedVertex.positionOffset),
        ]
        if !geometry.normals.isEmpty {
            attributes.append(.init(semantic: .normal, format: .float3, layoutIndex: 0, offset: GLTFDeformedVertex.normalOffset))
        }
        if !geometry.tangents.isEmpty {
            attributes.append(.init(semantic: .tangent, format: .float3, layoutIndex: 0, offset: GLTFDeformedVertex.tangentOffset))
            attributes.append(.init(semantic: .bitangent, format: .float3, layoutIndex: 0, offset: GLTFDeformedVertex.bitangentOffset))
        }
        var layouts = [LowLevelMesh.Layout(bufferIndex: 0, bufferStride: GLTFDeformedVertex.stride)]
        if !geometry.texcoords.isEmpty {
            attributes.append(.init(semantic: .uv0, format: .float2, layoutIndex: Self.texcoordBufferIndex, offset: 0))
            layouts.append(LowLevelMesh.Layout(bufferIndex: Self.texcoordBufferIndex,
                                               bufferStride: MemoryLayout<SIMD2<Float>>.stride))
        }
        tangentHandedness = Self.tangentHandedness(of: geometry)
        if tangentHandedness.isEmpty {
            tangentHandednessBufferIndex = nil
        } else {
            tangentHandednessBufferIndex = layouts.count
            attributes.append(.init(semantic: .uv1, format: .float2, layoutIndex: layouts.count, offset: 0))
            layouts.append(LowLevelMesh.Layout(bufferIndex: layouts.count, bufferStride: MemoryLayout<SIMD2<Float>>.stride))
        }
        descriptor = LowLevelMesh.Descriptor(vertexCapacity: geometry.vertexCount,
                                             vertexAttributes: attributes,
                                             vertexLayouts: layouts,
                                             indexCapacity: geometry.indices.count,
                                             indexType: .uint32)
    }

    /// Skinning and morphing turn the frame without mirroring it, so the rest pose decides the hand for good.
    private static func tangentHandedness(of geometry: GLTFMeshGeometry) -> [SIMD2<Float>] {
        guard !geometry.tangents.isEmpty, geometry.normals.count == geometry.vertexCount else { return [] }
        return (0..<geometry.vertexCount).map { index in
            let hand = simd_dot(simd_cross(geometry.normals[index], geometry.tangents[index]), geometry.bitangents[index])
            return SIMD2(hand < 0 ? -1 : 1, 0)
        }
    }
}
#endif
