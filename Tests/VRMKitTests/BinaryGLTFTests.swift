import Foundation
import Testing
import VRMKit
import VRMTestSupport

@Suite
struct BinaryGLTFTests {
    @Test
    func testSubdataCopiesTheRequestedElements() throws {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(Array(try data.subdata(offset: 1, size: 2, stride: 4, count: 2)) == [1, 2, 5, 6])
        #expect(Array(try data.subdata(offset: 2, size: 2, stride: 2, count: 3)) == [2, 3, 4, 5, 6, 7])
        // The last byte landing exactly on the end is still valid.
        #expect(Array(try data.subdata(offset: 8, size: 2, stride: 2, count: 1)) == [8, 9])
    }

    /// A buffer view is a slice of its buffer, so an accessor's offset counts from
    /// where the view starts, not the buffer.
    @Test
    func testSubdataOfASliceCountsFromTheSliceStart() throws {
        let view = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])[4...]

        #expect(Array(try view.subdata(offset: 1, size: 2, stride: 2, count: 2)) == [5, 6, 7, 8])
        #expect(Array(try view.subdata(offset: 1, size: 1, stride: 2, count: 2)) == [5, 7])
        // The view bounds the accessor: what the buffer holds past it is not part of
        // it, and the bytes before it are not addressable.
        #expect(throws: (any Error).self) { try view.subdata(offset: 4, size: 4, stride: 4, count: 1) }
    }

    /// An accessor that overruns its buffer view fails the load rather than reading
    /// out of bounds, and the extent computation must not trap: a hostile glTF can name
    /// counts and strides whose product overflows Int.
    @Test
    func testSubdataRejectsRangesBeyondTheBuffer() {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(throws: (any Error).self) { try data.subdata(offset: 0, size: 4, stride: 4, count: 3) }
        #expect(throws: (any Error).self) { try data.subdata(offset: 9, size: 2, stride: 2, count: 1) }
        #expect(throws: (any Error).self) { try data.subdata(offset: 8, size: 2, stride: 4, count: 2) }
        #expect(throws: (any Error).self) { try data.subdata(offset: -1, size: 2, stride: 2, count: 1) }
        #expect(throws: (any Error).self) { try data.subdata(offset: 0, size: 8, stride: 8, count: .max) }
        #expect(throws: (any Error).self) { try data.subdata(offset: .max, size: 1, stride: 1, count: 2) }
        #expect(throws: (any Error).self) { try data.subdata(offset: 0, size: .max, stride: .max, count: 3) }
        #expect(throws: (any Error).self) { try data.subdata(offset: .max - 1, size: 4, stride: 4, count: 1) }
    }

    /// A buffer view that overruns its buffer, or names one the file does not have,
    /// throws before any accessor is sliced out rather than trapping.
    @Test
    func testBufferViewDataRejectsRangesBeyondTheBuffer() throws {
        let overrunning = try document(withFirstBufferView: ["byteOffset": 0, "byteLength": .int(Int(UInt32.max))])
        #expect(throws: (any Error).self) { try overrunning.bufferViewData(at: 0) }

        let overflowing = try document(withFirstBufferView: ["byteOffset": .int(.max), "byteLength": 16])
        #expect(throws: (any Error).self) { try overflowing.bufferViewData(at: 0) }

        let negative = try document(withFirstBufferView: ["byteOffset": .int(-1), "byteLength": 16])
        #expect(throws: (any Error).self) { try negative.bufferViewData(at: 0) }

        let missingBuffer = try document(withFirstBufferView: ["buffer": 99])
        #expect(throws: (any Error).self) { try missingBuffer.bufferViewData(at: 0) }
    }

    /// UniVRM 0.x appends a model's thumbnail past the buffer's declared `byteLength`,
    /// so the resource is what bounds a view.
    @Test
    func testBufferViewDataReadsPastAnUnderstatedBufferLength() throws {
        func document(bufferByteLength: Int, bufferView: JSONObject) throws -> GLTFDocument {
            let data = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
                var buffers = json.objects("buffers")
                var bufferViews = json.objects("bufferViews")
                guard !buffers.isEmpty, !bufferViews.isEmpty else {
                    throw GLBRewriter.Error.invalidJSON
                }
                buffers[0]["byteLength"] = .int(bufferByteLength)
                json["buffers"] = .objects(buffers)
                bufferViews[0].merge(bufferView) { _, new in new }
                json["bufferViews"] = .objects(bufferViews)
            }
            return try GLTFDocument(data: data)
        }

        let beyond = try document(bufferByteLength: 64, bufferView: ["byteOffset": 60, "byteLength": 16])
        #expect(try beyond.bufferViewData(at: 0).data.count == 16)

        // A view past the end of the resource is still refused.
        let beyondTheResource = try document(bufferByteLength: 64,
                                             bufferView: ["byteOffset": 0, "byteLength": .int(Int(UInt32.max))])
        #expect(throws: (any Error).self) { try beyondTheResource.bufferViewData(at: 0) }
    }

    @Test
    func testBufferViewDataRejectsAnIndexBeyondTheFile() throws {
        let document = try GLTFDocument(data: VRMSampleAsset.aliciaSolid.data)
        #expect(throws: (any Error).self) { try document.bufferViewData(at: document.gltf.bufferViews.count) }
    }

    /// The fixture with fields of its first buffer view replaced, leaving the rest of
    /// the file intact.
    private func document(withFirstBufferView fields: JSONObject) throws -> GLTFDocument {
        let data = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var bufferViews = json.objects("bufferViews")
            guard !bufferViews.isEmpty else {
                throw GLBRewriter.Error.invalidJSON
            }
            bufferViews[0].merge(fields) { _, new in new }
            json["bufferViews"] = .objects(bufferViews)
        }
        return try GLTFDocument(data: data)
    }

    @Test
    func testRejectsAFileThatIsNotBinaryGLTF() {
        var notGLB = VRMSampleAsset.aliciaSolid.data
        notGLB.writeUInt32LE(0x12345678, at: 0)
        #expect(throws: (any Error).self) { try BinaryGLTF(data: notGLB) }
    }

    @Test
    func testRejectsATruncatedHeader() {
        let data = VRMSampleAsset.aliciaSolid.data
        // Cut short at each header field in turn: magic, version, total length, chunk 0
        // length, chunk 0 type, and mid-way through the JSON chunk.
        for count in [0, 4, 8, 12, 16, 20, 24] {
            #expect(throws: (any Error).self) { try BinaryGLTF(data: data.prefix(count)) }
        }
    }

    /// The length is the largest multiple of 4 a chunk can declare, so it gets past the
    /// alignment check to the one that bounds a chunk by the container.
    @Test
    func testRejectsChunkLengthsBeyondTheFile() {
        let overrunningLength: UInt32 = 0xFFFF_FFFC

        var jsonOverrun = VRMSampleAsset.aliciaSolid.data
        jsonOverrun.writeUInt32LE(overrunningLength, at: 12)
        #expect(throws: (any Error).self) { try BinaryGLTF(data: jsonOverrun) }

        var binaryOverrun = VRMSampleAsset.aliciaSolid.data
        let binaryChunkOffset = 20 + Int(binaryOverrun.uint32LE(at: 12))
        binaryOverrun.writeUInt32LE(overrunningLength, at: binaryChunkOffset)
        #expect(throws: (any Error).self) { try BinaryGLTF(data: binaryOverrun) }
    }

    /// The header length names the size of the whole GLB, so a shorter file is truncated
    /// and its chunk offsets cannot be trusted, and bytes past it are not part of one.
    @Test(arguments: [(declaredBeyondTheFile: 4, bytesPastTheHeaderLength: 0), (0, 4)])
    func testRejectsAHeaderLengthThatIsNotTheFileLength(declaredBeyondTheFile: Int, bytesPastTheHeaderLength: Int) {
        var data = VRMSampleAsset.aliciaSolid.data
        let declaredLength = data.count + declaredBeyondTheFile
        data.append(contentsOf: [UInt8](repeating: 0, count: bytesPastTheHeaderLength))
        data.writeUInt32LE(UInt32(declaredLength), at: 8)
        #expect(throws: (any Error).self) { try BinaryGLTF(data: data) }
    }

    /// The spec has readers ignore chunk types they do not know, so a file with one still
    /// loads with its JSON and BIN chunks intact.
    @Test
    func testSkipsChunkTypesItDoesNotKnow() throws {
        let unknownChunk = appendingChunk(type: 0x4E574E55, payload: Data([1, 2, 3, 4]),
                                          to: VRMSampleAsset.aliciaSolid.data)
        let binaryGltf = try BinaryGLTF(data: unknownChunk)
        #expect(binaryGltf.gltf.asset.version == "2.0")
        #expect(binaryGltf.binaryBuffer != nil)
    }

    /// A GLB whose first chunk is not the JSON chunk is not loadable: everything else in
    /// the container is described by it.
    @Test
    func testRejectsAFileWhoseFirstChunkIsNotJSON() {
        let header = VRMSampleAsset.aliciaSolid.data.prefix(12)
        let noJSON = appendingChunk(type: 0x4E574E55, payload: Data([1, 2, 3, 4]), to: Data(header))
        #expect(throws: (any Error).self) { try BinaryGLTF(data: noJSON) }
    }

    /// Bytes inside the declared length that are too few to start a chunk are described
    /// by nothing, so the container does not add up and must not load.
    @Test
    func testRejectsBytesLeftOverInsideTheHeaderLength() {
        var leftover = VRMSampleAsset.aliciaSolid.data
        leftover.append(contentsOf: [0, 0, 0, 0])
        leftover.writeUInt32LE(UInt32(leftover.count), at: 8)
        #expect(throws: (any Error).self) { try BinaryGLTF(data: leftover) }
    }

    /// Files in the wild state the BIN chunk's unpadded length, which is not the multiple
    /// of 4 the spec asks for, whether or not they then pad the file to a boundary. UniVRM
    /// loads them, so the length is taken as written and the padding is not a leftover.
    @Test(arguments: [true, false])
    func testLoadsABINChunkWhoseLengthIsNotAMultipleOf4(keepsPadding: Bool) throws {
        var unpadded = VRMSampleAsset.aliciaSolid.data
        let binaryChunkOffset = 20 + Int(unpadded.uint32LE(at: 12))
        let binaryLength = Int(unpadded.uint32LE(at: binaryChunkOffset))
        unpadded.writeUInt32LE(UInt32(binaryLength - 1), at: binaryChunkOffset)
        if !keepsPadding {
            unpadded.removeLast()
            unpadded.writeUInt32LE(UInt32(unpadded.count), at: 8)
        }

        let binaryGltf = try BinaryGLTF(data: unpadded)
        #expect(binaryGltf.binaryBuffer?.count == binaryLength - 1)
    }

    /// The spec fixes the BIN chunk at index 1, so a file pushing it behind an unknown
    /// chunk is malformed even though each chunk on its own is not.
    @Test
    func testRejectsABINChunkThatIsNotTheSecondChunk() {
        let data = VRMSampleAsset.aliciaSolid.data
        let binaryChunkOffset = 20 + Int(data.uint32LE(at: 12))
        var reordered = Data(data.prefix(binaryChunkOffset))
        reordered.appendUInt32LE(4)
        reordered.appendUInt32LE(0x4E574E55)
        reordered.append(contentsOf: [1, 2, 3, 4])
        reordered.append(data.suffix(from: binaryChunkOffset))
        reordered.writeUInt32LE(UInt32(reordered.count), at: 8)
        #expect(throws: (any Error).self) { try BinaryGLTF(data: reordered) }
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

    /// The container version and the asset version are independent, so a 2.0 container
    /// can still declare an asset this parser does not implement.
    @Test
    func testRejectsAnAssetVersionItDoesNotImplement() throws {
        let futureVersion = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var asset = json.object("asset") ?? [:]
            asset["version"] = "3.0"
            json["asset"] = .object(asset)
        }
        #expect(throws: (any Error).self) { try BinaryGLTF(data: futureVersion) }

        let futureMinVersion = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var asset = json.object("asset") ?? [:]
            asset["minVersion"] = "2.1"
            json["asset"] = .object(asset)
        }
        #expect(throws: (any Error).self) { try BinaryGLTF(data: futureMinVersion) }
    }

    /// glTF aligns MAT2 / MAT3 columns to 4 bytes, so with narrow components an element is
    /// wider than its components and the packed reader would mis-slice it. Those layouts
    /// are rejected; the MAT4 float layout VRM uses is not.
    @Test
    func testRejectsMatrixAccessorsWhoseColumnsArePadded() throws {
        let padded = try accessor(#"{"bufferView": 0, "count": 1, "componentType": 5121, "type": "MAT3"}"#)
        #expect(throws: (any Error).self) { try padded.packedData(bufferView: { _ in (Data(repeating: 0, count: 48), nil) }) }

        let unpadded = try accessor(#"{"bufferView": 0, "count": 1, "componentType": 5126, "type": "MAT4"}"#)
        let data = try unpadded.packedData(bufferView: { _ in (Data(repeating: 0, count: 64), nil) })
        #expect(data.count == 64)
    }

    /// Sparse indices substitute elements by position, so the spec requires them strictly
    /// increasing: a repeated index would leave the overlap depending on the copy order.
    @Test
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
        #expect(throws: (any Error).self) { try sparse.packedData(bufferView: provider(indices: [2, 2])) }
        #expect(throws: (any Error).self) { try sparse.packedData(bufferView: provider(indices: [2, 1])) }
        #expect(throws: Never.self) { try sparse.packedData(bufferView: provider(indices: [1, 2])) }
    }

    private func accessor(_ json: String) throws -> GLTF.Accessor {
        try JSONDecoder().decode(GLTF.Accessor.self, from: Data(json.utf8))
    }

    @Test
    func testZeroedAccessorDataRejectsOverflowingSizes() throws {
        #expect(throws: (any Error).self) { try Data(zeroedElementCount: .max, elementSize: 12) }
        #expect(throws: (any Error).self) { try Data(zeroedElementCount: -1, elementSize: 12) }
        // Nothing in the file bounds what such an accessor asks for, so the limit is what
        // stops a two-line glTF allocating a device out of memory.
        #expect(throws: (any Error).self) {
            try Data(zeroedElementCount: Data.maximumZeroFilledByteCount / 12 + 1, elementSize: 12)
        }
        #expect(try Data(zeroedElementCount: 3, elementSize: 4).count == 12)
    }
}
