import XCTest
import VRMKit
import VRMTestSupport

class BinaryGLTFTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
    }
    
    func testLoadVRM() {
        let binaryGltf = try! BinaryGLTF(data: VRMSampleAsset.aliciaSolid.data)
        let json = binaryGltf.jsonData
        XCTAssertEqual(json.asset.generator, "UniGLTF")
        XCTAssertEqual(json.asset.version, "2.0")
    }

    func testStridedSubdataCopiesBytes() throws {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let strided = try data.subdata(offset: 1, size: 2, stride: 4, count: 2)
        XCTAssertEqual(Array(strided), [1, 2, 5, 6])
    }

    func testTightlyPackedSubdataReturnsOnlyTheRequestedRange() throws {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let packed = try data.subdata(offset: 2, size: 2, stride: 2, count: 3)
        XCTAssertEqual(Array(packed), [2, 3, 4, 5, 6, 7])
    }

    /// An accessor that overruns its buffer view must fail the load instead of
    /// reading out of bounds.
    func testSubdataRejectsRangesBeyondTheBuffer() {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertThrowsError(try data.subdata(offset: 0, size: 4, stride: 4, count: 3))
        XCTAssertThrowsError(try data.subdata(offset: 9, size: 2, stride: 2, count: 1))
        XCTAssertThrowsError(try data.subdata(offset: 8, size: 2, stride: 4, count: 2))
        XCTAssertThrowsError(try data.subdata(offset: -1, size: 2, stride: 2, count: 1))
        // The last byte landing exactly on the end is still valid.
        XCTAssertNoThrow(try data.subdata(offset: 8, size: 2, stride: 2, count: 1))
    }

    /// The extent computation itself must not trap: a hostile glTF can name
    /// counts and strides whose product overflows Int.
    func testSubdataRejectsOverflowingExtentsWithoutTrapping() {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertThrowsError(try data.subdata(offset: 0, size: 8, stride: 8, count: .max))
        XCTAssertThrowsError(try data.subdata(offset: .max, size: 1, stride: 1, count: 2))
        XCTAssertThrowsError(try data.subdata(offset: 0, size: .max, stride: .max, count: 3))
        XCTAssertThrowsError(try data.subdata(offset: .max - 1, size: 4, stride: 4, count: 1))
    }

    /// A buffer view that overruns its buffer has to throw before any accessor
    /// can be sliced out of it.
    func testBufferViewDataRejectsRangesBeyondTheBuffer() throws {
        let overrunning = try binaryGLTF(withFirstBufferView: ["byteOffset": 0, "byteLength": Int(UInt32.max)])
        XCTAssertThrowsError(try overrunning.bufferViewData(at: 0))

        let overflowing = try binaryGLTF(withFirstBufferView: ["byteOffset": Int.max, "byteLength": 16])
        XCTAssertThrowsError(try overflowing.bufferViewData(at: 0))

        let negative = try binaryGLTF(withFirstBufferView: ["byteOffset": -1, "byteLength": 16])
        XCTAssertThrowsError(try negative.bufferViewData(at: 0))
    }

    /// A buffer's declared `byteLength` is where it logically ends, so the bytes
    /// a padded GLB BIN chunk holds past it are out of every view's reach.
    func testBufferViewDataRejectsRangesBeyondTheDeclaredBufferLength() throws {
        func binaryGLTF(bufferByteLength: Int, bufferView: [String: Any]) throws -> BinaryGLTF {
            let data = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
                guard var buffers = json["buffers"] as? [[String: Any]], !buffers.isEmpty,
                      var bufferViews = json["bufferViews"] as? [[String: Any]], !bufferViews.isEmpty else {
                    throw GLBRewriter.Error.invalidJSON
                }
                buffers[0]["byteLength"] = bufferByteLength
                json["buffers"] = buffers
                bufferViews[0].merge(bufferView) { _, new in new }
                json["bufferViews"] = bufferViews
            }
            return try BinaryGLTF(data: data)
        }

        let beyond = try binaryGLTF(bufferByteLength: 64, bufferView: ["byteOffset": 60, "byteLength": 16])
        XCTAssertThrowsError(try beyond.bufferViewData(at: 0))

        let upToTheEnd = try binaryGLTF(bufferByteLength: 64, bufferView: ["byteOffset": 48, "byteLength": 16])
        XCTAssertEqual(try upToTheEnd.bufferViewData(at: 0).data.count, 16)
    }

    func testBufferViewDataRejectsAnIndexBeyondTheFile() throws {
        let binaryGltf = try BinaryGLTF(data: VRMSampleAsset.aliciaSolid.data)
        XCTAssertThrowsError(try binaryGltf.bufferViewData(at: binaryGltf.jsonData.bufferViews?.count ?? 0))
    }

    /// The fixture with `byteOffset` / `byteLength` of its first buffer view
    /// replaced, leaving the rest of the file intact.
    private func binaryGLTF(withFirstBufferView fields: [String: Any]) throws -> BinaryGLTF {
        let data = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            guard var bufferViews = json["bufferViews"] as? [[String: Any]], !bufferViews.isEmpty else {
                throw GLBRewriter.Error.invalidJSON
            }
            bufferViews[0].merge(fields) { _, new in new }
            json["bufferViews"] = bufferViews
        }
        return try BinaryGLTF(data: data)
    }

    /// A file whose magic is not `glTF` has to fail the load.
    func testRejectsAFileThatIsNotBinaryGLTF() {
        var notGLB = VRMSampleAsset.aliciaSolid.data
        notGLB.writeUInt32LE(0x12345678, at: 0)
        XCTAssertThrowsError(try BinaryGLTF(data: notGLB))
    }

    func testRejectsATruncatedHeader() {
        let data = VRMSampleAsset.aliciaSolid.data
        // Cut short at each header field in turn: magic, version, total length,
        // chunk 0 length, chunk 0 type, and mid-way through the JSON chunk.
        for count in [0, 4, 8, 12, 16, 20, 24] {
            XCTAssertThrowsError(try BinaryGLTF(data: data.prefix(count)),
                                 "a \(count) byte file must not load")
        }
    }

    func testRejectsChunkLengthsBeyondTheFile() {
        var jsonOverrun = VRMSampleAsset.aliciaSolid.data
        jsonOverrun.writeUInt32LE(.max, at: 12)
        XCTAssertThrowsError(try BinaryGLTF(data: jsonOverrun))

        var binaryOverrun = VRMSampleAsset.aliciaSolid.data
        let binaryChunkOffset = 20 + Int(binaryOverrun.uint32LE(at: 12))
        binaryOverrun.writeUInt32LE(.max, at: binaryChunkOffset)
        XCTAssertThrowsError(try BinaryGLTF(data: binaryOverrun))
    }

    /// A buffer view naming a buffer the file does not have has to throw rather
    /// than trap on the subscript.
    func testBufferViewDataRejectsAnIndexBeyondTheBuffers() throws {
        let binaryGltf = try binaryGLTF(withFirstBufferView: ["buffer": 99])
        XCTAssertThrowsError(try binaryGltf.bufferViewData(at: 0))
    }

    /// The header length names the size of the whole GLB, so a file shorter than
    /// it is truncated and its chunk offsets cannot be trusted.
    func testRejectsAHeaderLengthBeyondTheFile() {
        var overrunLength = VRMSampleAsset.aliciaSolid.data
        overrunLength.writeUInt32LE(UInt32(overrunLength.count + 4), at: 8)
        XCTAssertThrowsError(try BinaryGLTF(data: overrunLength))
    }

    /// Bytes past the header length are not part of any chunk, so a file that
    /// carries them (exporter padding, a slice of a larger container) still loads.
    func testLoadsAFileWithBytesPastTheHeaderLength() throws {
        var trailingBytes = VRMSampleAsset.aliciaSolid.data
        trailingBytes.append(contentsOf: [0, 0, 0, 0])
        let binaryGltf = try BinaryGLTF(data: trailingBytes)
        XCTAssertEqual(binaryGltf.jsonData.asset.version, "2.0")
        XCTAssertNotNil(binaryGltf.binaryBuffer)
    }

    /// The spec has readers ignore chunk types they do not know, so a file with
    /// one still loads with its JSON and BIN chunks intact.
    func testSkipsChunkTypesItDoesNotKnow() throws {
        let unknownChunk = appendingChunk(type: 0x4E574E55, payload: Data([1, 2, 3, 4]),
                                          to: VRMSampleAsset.aliciaSolid.data)
        let binaryGltf = try BinaryGLTF(data: unknownChunk)
        XCTAssertEqual(binaryGltf.jsonData.asset.version, "2.0")
        XCTAssertNotNil(binaryGltf.binaryBuffer)
    }

    /// The header length bounds the chunks, so a chunk reaching past it is
    /// malformed even when the bytes it names are present in the file.
    func testRejectsAChunkBeyondTheHeaderLength() {
        var overrun = appendingChunk(type: 0x4E574E55, payload: Data([1, 2, 3, 4]),
                                     to: VRMSampleAsset.aliciaSolid.data)
        // Leave the trailing chunk in the file but outside the declared length.
        overrun.writeUInt32LE(UInt32(overrun.count - 4), at: 8)
        XCTAssertThrowsError(try BinaryGLTF(data: overrun))
    }

    /// A GLB whose first chunk is not the JSON chunk is not loadable: everything
    /// else in the container is described by it.
    func testRejectsAFileWhoseFirstChunkIsNotJSON() {
        let header = VRMSampleAsset.aliciaSolid.data.prefix(12)
        let noJSON = appendingChunk(type: 0x4E574E55, payload: Data([1, 2, 3, 4]), to: Data(header))
        XCTAssertThrowsError(try BinaryGLTF(data: noJSON))
    }

    /// Bytes inside the declared length that are too few to start a chunk are
    /// described by nothing, so the container does not add up and must not load.
    func testRejectsBytesLeftOverInsideTheHeaderLength() {
        var leftover = VRMSampleAsset.aliciaSolid.data
        leftover.append(contentsOf: [0, 0, 0, 0])
        leftover.writeUInt32LE(UInt32(leftover.count), at: 8)
        XCTAssertThrowsError(try BinaryGLTF(data: leftover))
    }

    /// Every chunk starts and ends on a 4 byte boundary, so a chunk length that
    /// is not a multiple of 4 misaligns every chunk behind it.
    func testRejectsAChunkLengthThatBreaksTheAlignment() {
        var misaligned = VRMSampleAsset.aliciaSolid.data
        misaligned.writeUInt32LE(misaligned.uint32LE(at: 12) - 1, at: 12)
        XCTAssertThrowsError(try BinaryGLTF(data: misaligned))
    }

    /// The spec fixes the BIN chunk at index 1, so a file that pushes it behind
    /// an unknown chunk is malformed even though each chunk on its own is not.
    func testRejectsABINChunkThatIsNotTheSecondChunk() {
        let data = VRMSampleAsset.aliciaSolid.data
        let binaryChunkOffset = 20 + Int(data.uint32LE(at: 12))
        var reordered = Data(data.prefix(binaryChunkOffset))
        reordered.appendUInt32LE(4)
        reordered.appendUInt32LE(0x4E574E55)
        reordered.append(contentsOf: [1, 2, 3, 4])
        reordered.append(data.suffix(from: binaryChunkOffset))
        reordered.writeUInt32LE(UInt32(reordered.count), at: 8)
        XCTAssertThrowsError(try BinaryGLTF(data: reordered))
    }

    /// `data` with one more chunk, its header length grown to cover it.
    private func appendingChunk(type: UInt32, payload: Data, to data: Data) -> Data {
        var extended = data
        extended.appendUInt32LE(UInt32(payload.count))
        extended.appendUInt32LE(type)
        extended.append(payload)
        if extended.count >= 12 {
            extended.writeUInt32LE(UInt32(extended.count), at: 8)
        }
        return extended
    }

    /// The GLB container version and the asset version are independent, so a 2.0
    /// container can still declare an asset this parser does not implement.
    func testRejectsAnAssetVersionItDoesNotImplement() throws {
        let futureVersion = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var asset = json["asset"] as? [String: Any] ?? [:]
            asset["version"] = "3.0"
            json["asset"] = asset
        }
        XCTAssertThrowsError(try BinaryGLTF(data: futureVersion))

        let futureMinVersion = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var asset = json["asset"] as? [String: Any] ?? [:]
            asset["minVersion"] = "2.1"
            json["asset"] = asset
        }
        XCTAssertThrowsError(try BinaryGLTF(data: futureMinVersion))
    }

    /// glTF aligns MAT2 / MAT3 columns to 4 bytes, so with narrow components an
    /// element is wider than its components and the packed reader would mis-slice
    /// it. Those layouts are rejected; the MAT4 float layout VRM uses is not.
    func testRejectsMatrixAccessorsWhoseColumnsArePadded() throws {
        let padded = try accessor(#"{"bufferView": 0, "count": 1, "componentType": 5121, "type": "MAT3"}"#)
        XCTAssertThrowsError(try padded.packedData(bufferView: { _ in (Data(repeating: 0, count: 48), nil) }))

        let unpadded = try accessor(#"{"bufferView": 0, "count": 1, "componentType": 5126, "type": "MAT4"}"#)
        let data = try unpadded.packedData(bufferView: { _ in (Data(repeating: 0, count: 64), nil) })
        XCTAssertEqual(data.count, 64)
    }

    /// Sparse indices substitute elements by position, so the spec requires them
    /// strictly increasing: a repeated index leaves the element it overlaps on
    /// depending on the copy order.
    func testSparseAccessorRequiresStrictlyIncreasingIndices() throws {
        let sparse = try accessor("""
        {"count": 4, "componentType": 5126, "type": "SCALAR",
         "sparse": {"count": 2,
                    "indices": {"bufferView": 0, "componentType": 5121},
                    "values": {"bufferView": 1}}}
        """)
        func provider(indices: [UInt8]) -> BufferViewProvider {
            { $0 == 0 ? (Data(indices), nil) : (Data(repeating: 1, count: 8), nil) }
        }
        XCTAssertThrowsError(try sparse.packedData(bufferView: provider(indices: [2, 2])))
        XCTAssertThrowsError(try sparse.packedData(bufferView: provider(indices: [2, 1])))
        XCTAssertNoThrow(try sparse.packedData(bufferView: provider(indices: [1, 2])))
    }

    private func accessor(_ json: String) throws -> GLTF.Accessor {
        try JSONDecoder().decode(GLTF.Accessor.self, from: Data(json.utf8))
    }

    func testZeroedAccessorDataRejectsOverflowingSizes() {
        XCTAssertThrowsError(try Data(zeroedElementCount: .max, elementSize: 12))
        XCTAssertThrowsError(try Data(zeroedElementCount: -1, elementSize: 12))
        XCTAssertEqual(try Data(zeroedElementCount: 3, elementSize: 4).count, 12)
    }
}
