import Foundation

// see:
// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md

public struct BinaryGLTF {
    public let version: GLTF.Version
    public let jsonData: GLTF /// chunk 0
    public let binaryBuffer: Data? /// chunk1

    /// magic equals 0x46546C67. It is ASCII string glTF, and can be used to identify data as Binary glTF.
    static let magic = 0x46546C67

    enum ChunkType: UInt32 {
        case json = 0x4E4F534A
        case bin = 0x004E4942
    }
}

package extension BinaryGLTF {
    func bufferViewData(at index: Int, relativeTo rootDirectory: URL? = nil) throws -> (data: Data, stride: Int?) {
        let bufferView = try jsonData.load(\.bufferViews)[index]
        let buffer = try bufferData(at: bufferView.buffer, relativeTo: rootDirectory)
        let data = buffer.subdata(in: bufferView.byteOffset..<bufferView.byteOffset + bufferView.byteLength)
        return (data, bufferView.byteStride)
    }

    func bufferData(at index: Int, relativeTo rootDirectory: URL? = nil) throws -> Data {
        let gltfBuffer = try jsonData.load(\.buffers)[index]
        return try Data(buffer: gltfBuffer, relativeTo: rootDirectory, binaryBuffer: binaryBuffer)
    }
}

extension BinaryGLTF {
    public init(jsonDataOnly data: Data) throws {
        var offset = MemoryLayout<UInt32>.size // skip `magic`
        let rawVersion: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
        guard let version = GLTF.Version(rawValue: rawVersion), version == .two else {
            throw VRMError.notSupportedVersion(rawVersion)
        }
        self.version = version

        _ = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size) as UInt32
        let chunk0Length: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
        let chunk0Type: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
        guard ChunkType(rawValue: chunk0Type) == .json else {
            throw VRMError.notSupportedChunkType(chunk0Type)
        }
        let jsonData = read(data, offset: &offset, size: Int(chunk0Length))
        let decoder = JSONDecoder()
        self.jsonData = try decoder.decode(GLTF.self, from: jsonData)
        binaryBuffer = nil
    }

    public init(data: Data) throws {
        var offset = MemoryLayout<UInt32>.size // skip `magic`
        let rawVersion: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
        guard let version = GLTF.Version(rawValue: rawVersion), version == .two else {
            throw VRMError.notSupportedVersion(rawVersion)
        }
        self.version = version

        let length: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
        let chunk0Length: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
        let chunk0Type: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
        guard ChunkType(rawValue: chunk0Type) == .json else {
            throw VRMError.notSupportedChunkType(chunk0Type)
        }
        let jsonData = read(data, offset: &offset, size: Int(chunk0Length))
        let decoder = JSONDecoder()
        self.jsonData = try decoder.decode(GLTF.self, from: jsonData)

        if length > offset {
            let chunk1Length: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
            let chunk1Type: UInt32 = try read(data, offset: &offset, size: MemoryLayout<UInt32>.size)
            guard ChunkType(rawValue: chunk1Type) == .bin else {
                throw VRMError.notSupportedChunkType(chunk1Type)
            }
            binaryBuffer = read(data, offset: &offset, size: Int(chunk1Length)) as Data
        } else {
            binaryBuffer = nil
        }
    }
}
