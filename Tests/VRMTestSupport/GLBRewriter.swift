import Foundation
import VRMKit

/// Rewrites the JSON chunk of a GLB in memory, so every test target can take a
/// bundled `.vrm`, change a few fields and hand the result to a loader.
public enum GLBRewriter {
    public enum Error: Swift.Error {
        case notGLB
        case invalidChunk
        case missingJSONChunk
        case invalidJSON
    }

    private static let magic: [UInt8] = [0x67, 0x6c, 0x54, 0x46]  // "glTF"
    private static let jsonChunkType: UInt32 = 0x4e4f534a         // "JSON"

    /// Whether the data is a GLB container rather than a JSON glTF.
    public static func isGLB(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == magic
    }

    /// Returns `data` with its glTF JSON replaced by whatever `modify` produces.
    public static func rewritingJSON(of data: Data,
                                     _ modify: (inout [String: JSONValue]) throws -> Void) throws -> Data {
        guard data.count >= 20, Array(data.prefix(4)) == magic else {
            throw Error.notGLB
        }

        var chunks: [(type: UInt32, data: Data)] = []
        var offset = 12
        while offset + 8 <= data.count {
            let length = Int(data.uint32LE(at: offset))
            let type = data.uint32LE(at: offset + 4)
            offset += 8
            guard offset + length <= data.count else { throw Error.invalidChunk }
            chunks.append((type, Data(data[offset ..< offset + length])))
            offset += length
        }

        guard let jsonIndex = chunks.firstIndex(where: { $0.type == jsonChunkType }) else {
            throw Error.missingJSONChunk
        }
        var jsonData = chunks[jsonIndex].data
        while jsonData.last == 0x20 || jsonData.last == 0x00 { jsonData.removeLast() }
        guard var json = try JSONValue(parsing: jsonData).objectValue else {
            throw Error.invalidJSON
        }
        try modify(&json)

        // GLB chunks are 4-byte aligned; JSON pads with spaces.
        var rewritten = try JSONValue.object(json).serialized()
        while rewritten.count % 4 != 0 { rewritten.append(0x20) }
        chunks[jsonIndex].data = rewritten

        var output = Data(magic)
        output.appendUInt32LE(data.uint32LE(at: 4))  // version
        output.appendUInt32LE(0)                     // total length, patched below
        for chunk in chunks {
            output.appendUInt32LE(UInt32(chunk.data.count))
            output.appendUInt32LE(chunk.type)
            output.append(chunk.data)
        }
        output.writeUInt32LE(UInt32(output.count), at: 8)
        return output
    }
}

public extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset ..< offset + 4, with: $0) }
    }
}
