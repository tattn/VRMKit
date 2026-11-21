import Testing
@testable import VRMKitRuntime

/// Orphan vertices cost skinning and morphing on the GPU without drawing anything,
/// so the decoder reads only the vertices the triangles draw and renumbers the triangles.
@Suite
struct GLTFGeometryCompactionTests {
    @Test
    func testUndrawnVerticesAreLeftOutAndIndicesRenumbered() {
        // Vertices 1 and 4 are never drawn; vertex 5 is used first, then 0 and 3.
        var indices: [UInt32] = [5, 0, 3, 3, 0, 2]

        let drawn = GLTFGeometryDecoder.drawnVertices(renumbering: &indices, vertexCount: 6)

        #expect(drawn == [5, 0, 3, 2])
        #expect(indices == [0, 1, 2, 2, 1, 3])
    }

    @Test
    func testFullyDrawnVerticesKeepTheirOrder() {
        var indices: [UInt32] = [2, 1, 0]
        #expect(GLTFGeometryDecoder.drawnVertices(renumbering: &indices, vertexCount: 3) == nil)
        #expect(indices == [2, 1, 0])
    }
}
