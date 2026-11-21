import Foundation
import SIMDCompat
import Testing
import VRMKit
@testable import VRMKitRuntime

/// Primitives that share one vertex buffer, as a VRM 0.x export lays a mesh out, each read
/// only the vertices they draw: every attribute and every morph target follows a vertex to
/// where its primitive puts it.
@Suite
struct GLTFSharedVertexBufferTests {
    private let positions: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0]]
    private let tangents: [SIMD4<Float>] = [[1, 0, 0, 1], [0, 1, 0, -1], [0, 0, 1, 1], [1, 1, 0, -1]]
    /// The one morph target's deltas, substituted sparsely over zeros for vertices 1 and 3.
    private let deltas: [Int: SIMD3<Float>] = [1: [0.5, 0, 0], 3: [0, 0.25, 0]]

    @Test
    func testEachPrimitiveReadsTheVerticesItDrawsInTheOrderItDrawsThem() async throws {
        let asset = try await GLTFAsset.load(document: GLTFDocument(data: document()))
        let geometry = try #require(asset.meshes.first).geometry

        // The first primitive draws vertices 2, 3 and 1, the second 0, 1 and 2.
        let drawn = [2, 3, 1, 0, 1, 2]
        #expect(geometry.positions == drawn.map { positions[$0] })
        #expect(geometry.indices == [0, 1, 2, 3, 4, 5])
        #expect(geometry.slots.map(\.vertexRange) == [0..<3, 3..<6])
        let drawnTangents = drawn.map { SIMD3(tangents[$0].x, tangents[$0].y, tangents[$0].z) }
        #expect(geometry.tangents == drawnTangents)
        #expect(geometry.bitangents == zip(drawn, drawnTangents).map { vertex, tangent in
            simd_cross(SIMD3(0, 0, 1), tangent) * (tangents[vertex].w < 0 ? -1 : 1)
        })
        #expect(geometry.blendShapeOffsets(forTarget: 0) == drawn.map { deltas[$0] ?? .zero })
    }

    /// Positions interleaved with normals, tangents of their own, one sparse target with no
    /// base and a material sampling a normal map, so that the tangents are read.
    private func document() throws -> Data {
        var buffer = Data()
        func append<T>(_ values: [T]) -> Int {
            let offset = buffer.count
            values.withUnsafeBytes { buffer.append(contentsOf: $0) }
            return offset
        }
        let interleaved: [Float] = positions.flatMap { [$0.x, $0.y, $0.z, 0, 0, 1] }
        let interleavedOffset = append(interleaved)
        let tangentOffset = append(tangents.flatMap { [$0.x, $0.y, $0.z, $0.w] })
        let indexOffset = append([UInt16]([2, 3, 1, 0, 1, 2]))
        let sparseIndexOffset = append([UInt32](deltas.keys.sorted().map(UInt32.init)))
        let sparseValueOffset = append(deltas.keys.sorted().flatMap { [deltas[$0]!.x, deltas[$0]!.y, deltas[$0]!.z] })

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [0, 1].map { primitive in
                [
                    "attributes": ["POSITION": 0, "NORMAL": 1, "TANGENT": 2],
                    "indices": 3 + primitive,
                    "material": 0,
                    "targets": [["POSITION": 5]],
                ] as [String: Any]
            }]],
            "materials": [["normalTexture": ["index": 0]]],
            "textures": [["source": 0]],
            "images": [["uri": "unused.png"]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 0, "byteOffset": 12, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC4"],
                ["bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR"],
                ["bufferView": 2, "byteOffset": 6, "componentType": 5123, "count": 3, "type": "SCALAR"],
                ["componentType": 5126, "count": 4, "type": "VEC3",
                 "sparse": ["count": deltas.count,
                            "indices": ["bufferView": 3, "componentType": 5125],
                            "values": ["bufferView": 4]]],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": interleavedOffset, "byteLength": interleaved.count * 4, "byteStride": 24],
                ["buffer": 0, "byteOffset": tangentOffset, "byteLength": tangents.count * 16],
                ["buffer": 0, "byteOffset": indexOffset, "byteLength": 12],
                ["buffer": 0, "byteOffset": sparseIndexOffset, "byteLength": deltas.count * 4],
                ["buffer": 0, "byteOffset": sparseValueOffset, "byteLength": deltas.count * 12],
            ],
            "buffers": [["byteLength": buffer.count,
                         "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()]],
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }
}
