import Foundation
import SIMDCompat
import Testing
import VRMKit
@testable import VRMKitRuntime

/// The primitives of one mesh laid out as one vertex array: one slot each, attributes a
/// primitive lacks padded with zeros, and the morph deltas packed target-major.
@Suite
struct GLTFMeshGeometryTests {
    private func primitive(positions: [SIMD3<Float>],
                           blendShapes: GLTFPrimitiveBlendShapes = GLTFPrimitiveBlendShapes(),
                           firstPersonMask: FirstPersonPrimitiveMask = .whole) -> GLTFPreparedPrimitive {
        var geometry = GLTFPrimitiveGeometry()
        geometry.positions = positions
        geometry.indices = Array(0..<UInt32(positions.count))
        geometry.blendShapes = blendShapes
        return GLTFPreparedPrimitive(geometry: geometry, cutsHead: false, firstPersonMask: firstPersonMask,
                                     jointInfluences: nil)
    }

    /// A target's deltas as a document stores them: tightly packed floats.
    private func deltas(_ offsets: [SIMD3<Float>]) throws -> AccessorReader {
        let bytes = offsets.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBytes { Data($0) }
        let accessor = try JSONDecoder().decode(GLTF.Accessor.self, from: Data("""
            {"bufferView": 0, "componentType": 5126, "count": \(offsets.count), "type": "VEC3"}
            """.utf8))
        return try AccessorReader(accessor: accessor) { _ in (bytes, nil) }
    }

    @Test
    func testPrimitivesShareOneVertexArrayAndKeepTheirOwnSlots() {
        let geometry = GLTFMeshGeometry(
            primitives: [
                primitive(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                          firstPersonMask: .nothing),
                primitive(positions: [SIMD3(0, 0, 2), SIMD3(-1, 0, 2), SIMD3(0, -1, 2)]),
            ],
            isSkinned: false,
            blendShapeTargetCount: 0
        )

        #expect(geometry.vertexCount == 6)
        #expect(geometry.slots.map(\.vertexRange) == [0..<3, 3..<6])
        #expect(geometry.triangleIndices(ofSlot: 1) == [3, 4, 5])
        #expect(geometry.triangleIndices(ofSlot: 0, isFirstPerson: true).isEmpty)
        #expect(geometry.slots[1].bounds == GLTFBounds(min: SIMD3(-1, -1, 2), max: SIMD3(0, 0, 2)))
        #expect(geometry.bounds == GLTFBounds(min: SIMD3(-1, -1, 0), max: SIMD3(1, 1, 2)))
        #expect(geometry.blendShapeOffsetBuffer == nil)
    }

    /// A primitive without targets reads zero deltas, and the buffer starts on a page so
    /// a GPU API can use it in place.
    @Test
    func testMorphDeltasArePackedTargetMajorInPageAlignedMemory() throws {
        let geometry = GLTFMeshGeometry(
            primitives: [
                primitive(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]),
                primitive(positions: [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1)],
                          blendShapes: GLTFPrimitiveBlendShapes(targets: [
                              try deltas([SIMD3(1, 2, 3), SIMD3(4, 5, 6), SIMD3(7, 8, 9)]),
                              try deltas([SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, -1)]),
                          ])),
            ],
            isSkinned: false,
            blendShapeTargetCount: 2
        )

        let buffer = try #require(geometry.blendShapeOffsetBuffer)
        #expect(buffer.byteCount == 2 * 6 * 12)
        let pageSize = Int(getpagesize())
        #expect(Int(bitPattern: buffer.baseAddress) % pageSize == 0)
        #expect(buffer.allocatedByteCount % pageSize == 0)
        #expect(geometry.blendShapeOffsets(forTarget: 0)
            == [.zero, .zero, .zero, SIMD3(1, 2, 3), SIMD3(4, 5, 6), SIMD3(7, 8, 9)])
        #expect(geometry.blendShapeOffsets(forTarget: 1)
            == [.zero, .zero, .zero, SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, -1)])
        #expect(geometry.blendShapeOffsets(forTarget: 2).isEmpty)
        #expect(geometry.slots.map(\.hasBlendShapes) == [false, true])
    }

    /// A primitive drawing part of a vertex buffer it shares reads each target's deltas for
    /// the vertices it draws only, and a target without deltas leaves them zero.
    @Test
    func testMorphDeltasAreReadForTheVerticesAPrimitiveDraws() throws {
        let geometry = GLTFMeshGeometry(
            primitives: [
                primitive(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                          blendShapes: GLTFPrimitiveBlendShapes(
                              targets: [nil, try deltas([SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(3, 0, 0), SIMD3(4, 0, 0)])],
                              sources: [3, 0, 2]
                          )),
            ],
            isSkinned: false,
            blendShapeTargetCount: 2
        )

        #expect(geometry.blendShapeOffsets(forTarget: 0) == [.zero, .zero, .zero])
        #expect(geometry.blendShapeOffsets(forTarget: 1) == [SIMD3(4, 0, 0), SIMD3(1, 0, 0), SIMD3(3, 0, 0)])
    }
}
