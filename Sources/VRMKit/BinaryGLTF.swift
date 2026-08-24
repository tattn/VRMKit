import Foundation

// see:
// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md

public struct BinaryGLTF {
    /// Chunk 0.
    public let jsonData: GLTF
    /// Chunk 0 as it was written, which the editing side re-parses so that the
    /// fields ``GLTF`` does not model survive a rewrite.
    package let jsonChunk: Data
    /// Chunk 1.
    public let binaryBuffer: Data?

    /// magic equals 0x46546C67. It is ASCII string glTF, and can be used to identify data as Binary glTF.
    static let magic: UInt32 = 0x46546C67

    /// The GLB header: magic, version and total length.
    static let headerLength = 12
    /// The header each chunk carries: its length and its type.
    static let chunkHeaderLength = 8

    enum ChunkType: UInt32 {
        case json = 0x4E4F534A
        case bin = 0x004E4942
    }
}

extension BinaryGLTF {
    /// Whether the data starts with the GLB magic and so should be parsed as a
    /// binary glTF container rather than as JSON.
    public static func isGLB(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian == magic
    }
}

extension BinaryGLTF {
    public init(data: Data) throws {
        var reader = BinaryReader(data)
        let magic = try reader.readUInt32()
        guard magic == Self.magic else {
            throw VRMError._dataInconsistent("not a binary glTF file: magic is 0x\(String(magic, radix: 16))")
        }

        let rawVersion = try reader.readUInt32()
        guard GLTF.Version(rawValue: rawVersion) == .two else {
            throw VRMError.notSupportedVersion(rawVersion)
        }

        // The header length covers the whole GLB, so fewer bytes than that means
        // the file is truncated and the chunk walk below cannot be trusted. Bytes
        // past it belong to no chunk and are ignored.
        let length = try reader.readUInt32()
        guard Int(length) <= data.count else {
            throw VRMError._dataInconsistent(
                "GLB header length \(length) overruns the \(data.count) byte file"
            )
        }

        // Chunk 0 holds the JSON, chunk 1 the optional BIN; every other chunk
        // type is one this parser does not know and the spec says to skip.
        var json: (gltf: GLTF, chunk: Data)?
        var binaryBuffer: Data?
        var chunkIndex = 0
        while reader.bytesRead + Self.chunkHeaderLength <= Int(length) {
            let chunkLength = try reader.readUInt32()
            let chunkType = try reader.readUInt32()
            // Every chunk starts and ends on a 4 byte boundary, so with the 12 byte
            // header and 8 byte chunk headers the payloads are multiples of 4 too.
            guard chunkLength.isMultiple(of: 4) else {
                throw VRMError._dataInconsistent(
                    "GLB chunk of \(chunkLength) bytes breaks the container's 4 byte alignment"
                )
            }
            guard reader.bytesRead + Int(chunkLength) <= Int(length) else {
                throw VRMError._dataInconsistent(
                    "GLB chunk of \(chunkLength) bytes overruns the \(length) byte container"
                )
            }
            let chunkData = try reader.readData(count: Int(chunkLength))
            switch ChunkType(rawValue: chunkType) {
            case .json:
                guard chunkIndex == 0 else {
                    throw VRMError._dataInconsistent("the JSON chunk must be the first GLB chunk")
                }
                json = (try JSONDecoder().decode(GLTF.self, from: chunkData), chunkData)
            case .bin:
                guard chunkIndex == 1 else {
                    throw VRMError._dataInconsistent("the BIN chunk must be the second GLB chunk")
                }
                binaryBuffer = chunkData
            case nil:
                guard json != nil else {
                    throw VRMError.notSupportedChunkType(chunkType)
                }
            }
            chunkIndex += 1
        }

        // Anything left inside the declared length belongs to no chunk, so the
        // container does not describe its own contents.
        guard reader.bytesRead == Int(length) else {
            throw VRMError._dataInconsistent(
                "GLB has \(Int(length) - reader.bytesRead) bytes left over after its last chunk"
            )
        }

        let chunk = try json ??? ._dataInconsistent("GLB carries no JSON chunk")
        // The GLB container version and the asset version are independent: a 2.x
        // container can still declare an asset this parser does not implement.
        try chunk.gltf.validateSupportedAssetVersion()
        self.jsonData = chunk.gltf
        self.jsonChunk = chunk.chunk
        self.binaryBuffer = binaryBuffer
    }
}
