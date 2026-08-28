import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#glb-file-format-specification

public struct BinaryGLTF: Sendable {
    /// Chunk 0.
    public let gltf: GLTF
    /// Chunk 0 as it was parsed, kept whole so that what ``GLTF`` does not model survives
    /// a rewrite.
    package let jsonTree: JSONValue
    /// Chunk 1.
    public let binaryBuffer: Data?

    /// The ASCII `glTF` a GLB starts with.
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
    /// Whether the data starts with the GLB magic and so is a binary glTF container.
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

        // The header length is the whole container. `Int(exactly:)`: a GLB may declare up to
        // 4 GB, which traps a 32 bit Int on watchOS.
        let rawLength = try reader.readUInt32()
        guard let length = Int(exactly: rawLength), length == data.count else {
            throw VRMError._dataInconsistent(
                "GLB header length \(rawLength) is not the length of the \(data.count) byte file"
            )
        }

        // Chunk 0 holds the JSON, chunk 1 the optional BIN. The spec says to skip other types.
        var json: (gltf: GLTF, tree: JSONValue)?
        var binaryBuffer: Data?
        var chunkIndex = 0
        while length - reader.bytesRead >= Self.chunkHeaderLength {
            let rawChunkLength = try reader.readUInt32()
            let chunkType = try reader.readUInt32()
            guard rawChunkLength.isMultiple(of: 4) else {
                throw VRMError._dataInconsistent(
                    "GLB chunk of \(rawChunkLength) bytes breaks the container's 4 byte alignment"
                )
            }
            guard let chunkLength = Int(exactly: rawChunkLength),
                  chunkLength <= length - reader.bytesRead else {
                throw VRMError._dataInconsistent(
                    "GLB chunk of \(rawChunkLength) bytes overruns the \(length) byte container"
                )
            }
            let chunkData = try reader.readData(count: chunkLength)
            switch ChunkType(rawValue: chunkType) {
            case .json:
                guard chunkIndex == 0 else {
                    throw VRMError._dataInconsistent("the JSON chunk must be the first GLB chunk")
                }
                // Parsed once: the typed model decodes off the same tree editing reads.
                let tree = try JSONValue(parsing: chunkData)
                json = (try tree.decode(GLTF.self), tree)
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

        // Bytes left inside the declared length belong to no chunk.
        guard reader.bytesRead == length else {
            throw VRMError._dataInconsistent(
                "GLB has \(length - reader.bytesRead) bytes left over after its last chunk"
            )
        }

        let chunk = try json ??? ._dataInconsistent("GLB carries no JSON chunk")
        // The container version and the asset version are independent.
        try chunk.gltf.validateSupportedAssetVersion()
        self.gltf = chunk.gltf
        self.jsonTree = chunk.tree
        self.binaryBuffer = binaryBuffer
    }
}
