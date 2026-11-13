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

    /// A model's morph targets read as displacements and names, and applying them by hand
    /// leaves a plain mesh behind.
    @Test
    func testMorphTargetsAreReadAndDropped() throws {
        let glb = try Self.morphedTriangle()
        var document = try GLTFEditableDocument(data: glb)
        let mesh = GLTFMeshIndex(0)

        #expect(try document.morphTargetNames(meshAt: mesh) == ["up", "still", "sparse"])
        let displacements = try document.morphTargetDisplacements(ofPrimitive: 0, meshAt: mesh)
        #expect(displacements == [[SIMD3(0, 0, 1), SIMD3(0, 0, 2), SIMD3(0, 0, 3)],
                                  [.zero, .zero, .zero],
                                  [.zero, .zero, SIMD3(4, 5, 6)]])
        #expect(try document.indices(ofPrimitive: 0, meshAt: mesh) == [0, 1, 2])

        try document.removeMorphTargets(meshAt: mesh)
        let saved = try GLTFEditableDocument(data: document.serialize())
        #expect(try saved.morphTargetNames(meshAt: mesh).isEmpty)
        #expect(try saved.morphTargetDisplacements(ofPrimitive: 0, meshAt: mesh).isEmpty)
        #expect(try saved.typed().meshes[0].primitives[0].targets == nil)
        #expect(try saved.positions(ofPrimitive: 0, meshAt: mesh) == Self.triangle.positions)
    }

    /// Pruning stops declaring mesh quantization once the quantized data is gone, and keeps
    /// declaring it while a vertex attribute still needs it.
    @Test
    func testPruningUndeclaresMeshQuantizationNothingUses() throws {
        var document = GLTFEditableDocument()
        try document.addMesh(Self.triangle)
        let quantized = document.appendAccessors([
            .init(data: Data(count: 24), type: .VEC3, componentType: .short, count: 3, target: nil)
        ])[0]
        document.json.updateObject(at: quantized, in: .accessors) { $0["normalized"] = .bool(true) }
        document.json.updateObject(at: 0, in: .meshes) { mesh in
            mesh.mapObjects("primitives") { primitive in
                var primitive = primitive
                primitive["targets"] = .objects([["POSITION": .int(quantized)]])
                return primitive
            }
        }
        document.declareExtensions(used: [], required: ["KHR_mesh_quantization"])

        try document.prune()
        #expect(try document.typed().extensionsRequired == ["KHR_mesh_quantization"])

        try document.removeMorphTargets(meshAt: GLTFMeshIndex(0))
        try document.prune()
        let model = try GLTFEditableDocument(data: document.serialize()).typed()
        #expect(model.extensionsRequired.isEmpty)
        #expect(model.extensionsUsed.isEmpty)
    }

    /// The triangle with three morph targets: one moving POSITION, one carrying no POSITION at all,
    /// and one through a sparse accessor naming only the vertex it moves.
    private static func morphedTriangle() throws -> Data {
        var document = GLTFEditableDocument()
        try document.addMesh(triangle)
        let deltas = document.appendAccessors([
            .init(data: GLTFEditableDocument.packed([SIMD3<Float>(0, 0, 1), SIMD3(0, 0, 2), SIMD3(0, 0, 3)]),
                  type: .VEC3, componentType: .float, count: 3, target: nil, bounds: ([0, 0, 1], [0, 0, 3]))
        ])[0]
        let sparseParts = document.appendAccessors([
            .init(data: Data([2, 0]), type: .SCALAR, componentType: .unsignedShort, count: 1, target: nil),
            .init(data: GLTFEditableDocument.packed([SIMD3<Float>(4, 5, 6)]),
                  type: .VEC3, componentType: .float, count: 1, target: nil)
        ])
        let views = sparseParts.map { document.json.objects(.accessors)[$0].int("bufferView") ?? 0 }
        let sparse = document.json.appendObject(
            ["componentType": 5126, "count": 3, "type": "VEC3",
             "sparse": ["count": 1,
                        "indices": ["bufferView": .int(views[0]), "componentType": 5123],
                        "values": ["bufferView": .int(views[1])]]],
            to: .accessors)
        document.json.updateObject(at: 0, in: .meshes) { mesh in
            mesh["extras"] = .object(["targetNames": .array([.string("up"), .string("still"), .string("sparse")])])
            mesh.mapObjects("primitives") { primitive in
                var primitive = primitive
                primitive["targets"] = .objects([["POSITION": .int(deltas)], [:], ["POSITION": .int(sparse)]])
                return primitive
            }
        }
        return try document.serialize()
    }
}
