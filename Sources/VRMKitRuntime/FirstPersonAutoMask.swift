import simd
import VRMKit

/// What a first-person camera draws of one skinned primitive whose mesh VRM
/// annotates `auto`.
///
/// VRM takes out the triangles the head draws, so a model wearing one mesh from
/// head to foot still has a body to look down at.
package enum FirstPersonPrimitiveMask: Equatable {
    /// The head draws nothing of it, so it is drawn whole.
    case whole
    /// The head draws all of it, so nothing is drawn.
    case nothing
    /// The triangles left once the head's are taken out.
    case triangles([UInt32])
}

package enum FirstPersonAutoMask {
    /// The head bone and every bone hanging off it, as the joint indices
    /// `JOINTS_0` spells them.
    package static func headJoints(skinJoints: [Int],
                                   headNode: Int,
                                   hierarchy: GLTFNodeHierarchy) -> Set<UInt32> {
        var joints: Set<UInt32> = []
        for (joint, node) in skinJoints.enumerated() where hierarchy.lineage(of: node).contains(headNode) {
            joints.insert(UInt32(joint))
        }
        return joints
    }

    /// The vertices a head joint draws, one influence of any weight at all
    /// being enough.
    package static func headVertices(joints: [SIMD4<UInt32>],
                                     weights: [SIMD4<Float>],
                                     headJoints: Set<UInt32>) -> Set<Int> {
        guard !headJoints.isEmpty, joints.count == weights.count else { return [] }
        var vertices: Set<Int> = []
        for vertex in joints.indices {
            let influences = joints[vertex]
            let weight = weights[vertex]
            for lane in 0..<4 where weight[lane] > 0 && headJoints.contains(influences[lane]) {
                vertices.insert(vertex)
                break
            }
        }
        return vertices
    }

    /// The triangles no head joint draws, a triangle going as soon as one of its
    /// vertices is the head's.
    package static func mask(indices: [UInt32],
                             joints: [SIMD4<UInt32>],
                             weights: [SIMD4<Float>],
                             headJoints: Set<UInt32>) -> FirstPersonPrimitiveMask {
        mask(indices: indices, headVertices: headVertices(joints: joints,
                                                          weights: weights,
                                                          headJoints: headJoints))
    }

    /// The same, for a renderer that already knows the head's vertices.
    /// `vertex` reads the vertex a drawn index stands for, which is not the
    /// index itself where flat shading unshared them.
    package static func mask(indices: [UInt32],
                             headVertices: Set<Int>,
                             vertex: (UInt32) -> Int = { Int($0) }) -> FirstPersonPrimitiveMask {
        guard !headVertices.isEmpty else { return .whole }

        var kept: [UInt32] = []
        kept.reserveCapacity(indices.count)
        for corner in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let triangle = indices[corner...(corner + 2)]
            guard !triangle.contains(where: { headVertices.contains(vertex($0)) }) else { continue }
            kept.append(contentsOf: triangle)
        }
        if kept.count == indices.count - indices.count % 3 { return .whole }
        return kept.isEmpty ? .nothing : .triangles(kept)
    }
}
