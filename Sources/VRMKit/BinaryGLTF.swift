import Foundation

// see:
// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md

public struct BinaryGLTF {
    public let version: GLTF.Version
    public let jsonData: GLTF /// chunk 0
    public let binaryBuffer: Data? /// chunk1

    /// magic equals 0x46546C67. It is ASCII string glTF, and can be used to identify data as Binary glTF.
    static let magic: UInt32 = 0x46546C67

    enum ChunkType: UInt32 {
        case json = 0x4E4F534A
        case bin = 0x004E4942
    }
}

package extension BinaryGLTF {
    func bufferViewData(at index: Int, relativeTo rootDirectory: URL? = nil) throws -> (data: Data, stride: Int?) {
        let bufferView = try jsonData.load(\.bufferViews, at: index)
        let buffer = try bufferData(at: bufferView.buffer, relativeTo: rootDirectory)
        let end = bufferView.byteOffset.addingReportingOverflow(bufferView.byteLength)
        guard bufferView.byteOffset >= 0, bufferView.byteLength >= 0,
              !end.overflow, end.partialValue <= buffer.count else {
            throw VRMError._dataInconsistent(
                "buffer view (offset: \(bufferView.byteOffset), length: \(bufferView.byteLength)) overruns its \(buffer.count) byte buffer"
            )
        }
        return (buffer.subdata(in: bufferView.byteOffset..<end.partialValue), bufferView.byteStride)
    }

    func bufferData(at index: Int, relativeTo rootDirectory: URL? = nil) throws -> Data {
        let gltfBuffer = try jsonData.load(\.buffers, at: index)
        return try Data(buffer: gltfBuffer, relativeTo: rootDirectory, binaryBuffer: binaryBuffer)
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
        guard let version = GLTF.Version(rawValue: rawVersion), version == .two else {
            throw VRMError.notSupportedVersion(rawVersion)
        }
        self.version = version

        // The header length covers the whole GLB, so fewer bytes than that means
        // the file is truncated and the chunk walk below cannot be trusted. Bytes
        // past it belong to no chunk and are ignored.
        let length = try reader.readUInt32()
        guard Int(length) <= data.count else {
            throw VRMError._dataInconsistent(
                "GLB header length \(length) overruns the \(data.count) byte file"
            )
        }

        let chunk0Length = try reader.readUInt32()
        let chunk0Type = try reader.readUInt32()
        guard ChunkType(rawValue: chunk0Type) == .json else {
            throw VRMError.notSupportedChunkType(chunk0Type)
        }
        let jsonData = try reader.readData(count: Int(chunk0Length))
        let gltf = try JSONDecoder().decode(GLTF.self, from: jsonData)
        // The GLB container version and the asset version are independent: a 2.x
        // container can still declare an asset this parser does not implement.
        guard gltf.asset.version.hasPrefix("2.") else {
            throw VRMError._notSupported("glTF asset version \(gltf.asset.version) is not supported")
        }
        if let minVersion = gltf.asset.minVersion, minVersion != "2.0" {
            throw VRMError._notSupported("glTF asset minVersion \(minVersion) is not supported")
        }
        self.jsonData = gltf

        if length > reader.bytesRead {
            let chunk1Length = try reader.readUInt32()
            let chunk1Type = try reader.readUInt32()
            guard ChunkType(rawValue: chunk1Type) == .bin else {
                throw VRMError.notSupportedChunkType(chunk1Type)
            }
            binaryBuffer = try reader.readData(count: Int(chunk1Length))
        } else {
            binaryBuffer = nil
        }
    }
}
