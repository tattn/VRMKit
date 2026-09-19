#if canImport(RealityKit)
import Testing
import simd
@testable import VRMRealityKit

/// Orphan vertices cost skinning and morphing on the GPU without drawing anything,
/// so the decoder drops them and renumbers the triangles.
@Suite
struct GLTFGeometryCompactionTests {
    @Test
    func testUnreferencedVerticesAreDroppedAndIndicesRenumbered() {
        var geometry = GLTFPrimitiveGeometry()
        geometry.positions = (0..<6).map { SIMD3<Float>(Float($0), 0, 0) }
        geometry.normals = (0..<6).map { _ in SIMD3<Float>(0, 1, 0) }
        geometry.texcoords = (0..<6).map { SIMD2<Float>(Float($0) / 10, 0) }
        geometry.joints = (0..<6).map { SIMD4<UInt32>(UInt32($0), 0, 0, 0) }
        geometry.weights = (0..<6).map { _ in SIMD4<Float>(1, 0, 0, 0) }
        geometry.blendShapeOffsets = [(0..<6).map { SIMD3<Float>(0, Float($0), 0) }]
        // Vertices 1 and 4 are never drawn; vertex 5 is used first, then 0 and 3.
        geometry.indices = [5, 0, 3, 3, 0, 2]

        geometry.dropUnreferencedVertices()

        #expect(geometry.positions.map(\.x) == [5, 0, 3, 2])
        #expect(geometry.indices == [0, 1, 2, 2, 1, 3])
        #expect(geometry.texcoords.map(\.x) == [0.5, 0, 0.3, 0.2])
        #expect(geometry.joints.map(\.x) == [5, 0, 3, 2])
        #expect(geometry.weights.count == 4)
        #expect(geometry.normals.count == 4)
        #expect(geometry.blendShapeOffsets[0].map(\.y) == [5, 0, 3, 2])
    }

    @Test
    func testFullyReferencedGeometryIsLeftAlone() {
        var geometry = GLTFPrimitiveGeometry()
        geometry.positions = (0..<3).map { SIMD3<Float>(Float($0), 0, 0) }
        geometry.indices = [2, 1, 0]
        geometry.dropUnreferencedVertices()
        #expect(geometry.positions.count == 3)
        #expect(geometry.indices == [2, 1, 0])
    }
}
#endif
