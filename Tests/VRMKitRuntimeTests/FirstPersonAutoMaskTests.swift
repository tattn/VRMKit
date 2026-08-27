import Testing
import VRMKit
@testable import VRMKitRuntime
import simd

/// VRM draws an `auto` mesh to a first-person camera with the head's triangles
/// taken out, so a model wearing one mesh from head to foot still has a body to
/// look down at.
@Suite
struct FirstPersonAutoMaskTests {
    /// Two triangles over four vertices: 0 and 1 are body, 2 and 3 head.
    private let indices: [UInt32] = [0, 1, 2, 1, 2, 3]
    private let joints: [SIMD4<UInt32>] = [
        SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0),
    ]
    private let weights: [SIMD4<Float>] = [
        SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0),
    ]

    @Test
    func testATriangleGoesAsSoonAsOneOfItsVerticesIsTheHeads() {
        let mask = FirstPersonAutoMask.mask(indices: indices, joints: joints, weights: weights, headJoints: [1])

        #expect(mask == .nothing)
    }

    @Test
    func testTheTrianglesNoHeadJointDrawsAreKept() {
        let indices: [UInt32] = [0, 1, 2] + [0, 1, 0]
        let mask = FirstPersonAutoMask.mask(indices: indices, joints: joints, weights: weights, headJoints: [1])

        #expect(mask == .triangles([0, 1, 0]))
    }

    /// A mesh the head draws nothing of needs no second mesh at all.
    @Test
    func testAMeshNoHeadJointDrawsIsKeptWhole() {
        #expect(FirstPersonAutoMask.mask(indices: indices, joints: joints, weights: weights,
                                         headJoints: [2]) == .whole)
        #expect(FirstPersonAutoMask.mask(indices: indices, joints: joints, weights: weights,
                                         headJoints: []) == .whole)
        #expect(FirstPersonAutoMask.mask(indices: indices, joints: [], weights: [],
                                         headJoints: [1]) == .whole)
    }

    /// An influence of no weight draws nothing, so it claims no vertex.
    @Test
    func testAnInfluenceOfNoWeightDoesNotMakeAVertexTheHeads() {
        let weights = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: 4)
        let joints: [SIMD4<UInt32>] = [
            SIMD4(0, 1, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 1, 0, 0),
        ]

        #expect(FirstPersonAutoMask.mask(indices: indices, joints: joints, weights: weights,
                                         headJoints: [1]) == .whole)
    }

    /// The head draws through its own bone and everything hanging off it,
    /// numbered as `JOINTS_0` spells them rather than as nodes.
    @Test
    func testTheHeadJointsAreTheHeadBoneAndWhatHangsOffIt() throws {
        // 0 -> 1 (head) -> 2, and 3 beside them.
        let hierarchy = try GLTFNodeHierarchy(childIndices: [[1], [2], [], []])

        let joints = FirstPersonAutoMask.headJoints(skinJoints: [3, 2, 0, 1], headNode: 1, hierarchy: hierarchy)

        #expect(joints == [1, 3])
    }
}
