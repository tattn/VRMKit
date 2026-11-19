#if canImport(RealityKit)
import Foundation
import simd
import VRMKitRuntime

/// The vertex data a ``GLTFMeshSource`` hands the GPU, laid out from a mesh's geometry.
///
/// Laying it out touches every vertex, which holds up the actor building the entities for
/// as long as the model is large, so the loader lays it out in its prepare pass instead.
struct GLTFMeshVertices: Sendable {
    /// The rest pose as ``GLTFDeformedVertex`` lays a vertex out, zero where the mesh has no
    /// normals or tangents: what the kernel deforms from, and what a mesh draws until then.
    let rest: [Float]
    /// Per vertex, x is 1 where the rest tangent, bitangent and normal make a right-handed
    /// frame and -1 where they make a left-handed one (mirrored UVs). RealityKit hands a
    /// surface shader the tangent of a right-handed frame, turning it over where the frame is
    /// left-handed, so MToon turns it back by this sign as glTF's tangent `w` would. Empty for
    /// a mesh without tangents.
    let tangentHandedness: [SIMD2<Float>]

    init(_ geometry: GLTFMeshGeometry) {
        let floatsPerVertex = GLTFDeformedVertex.stride / MemoryLayout<Float>.stride
        var rest = [Float](repeating: 0, count: geometry.vertexCount * floatsPerVertex)
        rest.withUnsafeMutableBufferPointer { rest in
            func write(_ vectors: [SIMD3<Float>], at offset: Int) {
                let first = offset / MemoryLayout<Float>.stride
                for (index, vector) in vectors.enumerated() where index < geometry.vertexCount {
                    let base = index * floatsPerVertex + first
                    rest[base] = vector.x
                    rest[base + 1] = vector.y
                    rest[base + 2] = vector.z
                }
            }
            write(geometry.positions, at: GLTFDeformedVertex.positionOffset)
            write(geometry.normals, at: GLTFDeformedVertex.normalOffset)
            if !geometry.tangents.isEmpty {
                write(geometry.tangents, at: GLTFDeformedVertex.tangentOffset)
                write(geometry.bitangents, at: GLTFDeformedVertex.bitangentOffset)
            }
        }
        self.rest = rest
        tangentHandedness = Self.tangentHandedness(of: geometry)
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
