import Foundation
import Testing
import SIMDCompat
@testable import VRMKit

@Suite
struct GLTFVertexEditingTests {
    private static let triangle = GLTFTriangleMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                                   normals: [SIMD3](repeating: SIMD3(0, 0, 1), count: 3),
                                                   indices: [0, 1, 2])

    /// Moved vertices read back from the saved file, with the bounds glTF requires of POSITION.
    @Test
    func testMovedVerticesSurviveSaving() throws {
        var document = GLTFEditableDocument()
        try document.addMesh(Self.triangle)
        let mesh = GLTFMeshIndex(0)
        #expect(try document.positions(ofPrimitive: 0, meshAt: mesh) == Self.triangle.positions)
        #expect(try document.normals(ofPrimitive: 0, meshAt: mesh) == Self.triangle.normals)

        let moved = Self.triangle.positions.map { $0 * 2 + SIMD3(0, 0, 3) }
        let turned = [SIMD3<Float>](repeating: SIMD3(1, 0, 0), count: 3)
        try document.setPositions(moved, normals: turned, ofPrimitive: 0, meshAt: mesh)

        let saved = try GLTFEditableDocument(data: document.serialize())
        #expect(try saved.positions(ofPrimitive: 0, meshAt: mesh) == moved)
        #expect(try saved.normals(ofPrimitive: 0, meshAt: mesh) == turned)
        let model = try saved.typed()
        let accessor = model.accessors[try #require(model.meshes[0].primitives[0].attributes[.POSITION])]
        #expect(accessor.min == [0, 0, 3])
        #expect(accessor.max == [2, 2, 3])
    }

    /// The normals stay when only the positions are given, and a wrong count changes nothing.
    @Test
    func testPositionsAloneKeepTheNormalsAndAWrongCountIsRefused() throws {
        var document = GLTFEditableDocument()
        try document.addMesh(Self.triangle)
        let mesh = GLTFMeshIndex(0)

        try document.setPositions(Self.triangle.positions.map { $0 + SIMD3(1, 1, 1) }, ofPrimitive: 0, meshAt: mesh)
        #expect(try document.normals(ofPrimitive: 0, meshAt: mesh) == Self.triangle.normals)

        #expect(throws: VRMError.self) {
            try document.setPositions([SIMD3(0, 0, 0)], ofPrimitive: 0, meshAt: mesh)
        }
        #expect(throws: VRMError.self) {
            _ = try document.positions(ofPrimitive: 1, meshAt: mesh)
        }
        #expect(try document.positions(ofPrimitive: 0, meshAt: mesh)[0] == SIMD3(1, 1, 1))
    }
}
