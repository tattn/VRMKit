import Foundation
import SIMDCompat
import Testing
@testable import VRMKitRuntime

/// The primitives of one mesh laid out as one vertex array: one slot each, attributes a
/// primitive lacks padded with zeros, and the morph deltas packed target-major.
@Suite
struct GLTFMeshGeometryTests {
    private func primitive(positions: [SIMD3<Float>],
                           blendShapeOffsets: [[SIMD3<Float>]] = [],
                           firstPersonMask: FirstPersonPrimitiveMask = .whole) -> GLTFPreparedPrimitive {
        var geometry = GLTFPrimitiveGeometry()
        geometry.positions = positions
        geometry.indices = Array(0..<UInt32(positions.count))
        geometry.blendShapeOffsets = blendShapeOffsets
        return GLTFPreparedPrimitive(geometry: geometry, cutsHead: false, firstPersonMask: firstPersonMask,
                                     jointInfluences: nil)
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
                          blendShapeOffsets: [
                              [SIMD3(1, 2, 3), SIMD3(4, 5, 6), SIMD3(7, 8, 9)],
                              [SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, -1)],
                          ]),
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
}
