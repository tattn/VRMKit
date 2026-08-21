import Foundation

/// A parsed glTF asset together with the context needed to resolve its binary
/// resources (the GLB BIN chunk, external files and data URIs), so that they
/// stay resolvable after loading, e.g. for lazily decoded animation accessors.
public final class GLTFDocument {
    public let gltf: GLTF
    /// GLB BIN chunk (chunk 1), when the document came from a GLB container.
    package let binaryBuffer: Data?
    /// Base directory for external buffer / image URIs.
    package let rootDirectory: URL?

    /// Decoded buffers, keyed by buffer index: resolving one re-reads an external
    /// file or base64-decodes a whole data URI.
    ///
    /// Buffer *views* are deliberately not cached: they are copies out of these
    /// buffers, and keeping them would hold the file's bytes a second time.
    private var buffers: [Int: Data] = [:]

    package init(gltf: GLTF, binaryBuffer: Data?, rootDirectory: URL?) {
        self.gltf = gltf
        self.binaryBuffer = binaryBuffer
        self.rootDirectory = rootDirectory
    }

    /// Wraps an already-parsed GLB container.
    public convenience init(binary: BinaryGLTF, rootDirectory: URL? = nil) {
        self.init(gltf: binary.jsonData, binaryBuffer: binary.binaryBuffer, rootDirectory: rootDirectory)
    }

    /// Wraps an already-decoded JSON glTF whose resources are external files or
    /// data URIs resolved against `rootDirectory`.
    public convenience init(gltf: GLTF, rootDirectory: URL? = nil) {
        self.init(gltf: gltf, binaryBuffer: nil, rootDirectory: rootDirectory)
    }
}

package extension GLTFDocument {
    func bufferData(at index: Int) throws -> Data {
        if let cached = buffers[index] { return cached }
        let gltfBuffer = try gltf.load(\.buffers, at: index)
        let data = try Data(buffer: gltfBuffer, relativeTo: rootDirectory, binaryBuffer: binaryBuffer)
        buffers[index] = data
        return data
    }

    /// ``bufferViewData(at:)`` as a ``BufferViewProvider``.
    var bufferViewProvider: BufferViewProvider {
        { [self] index in
            let (data, stride) = try bufferViewData(at: index)
            return (bufferView: data, stride: stride)
        }
    }

    func bufferViewData(at index: Int) throws -> (data: Data, stride: Int?) {
        let bufferView = try gltf.load(\.bufferViews, at: index)
        let buffer = try bufferData(at: bufferView.buffer)
        // The declared `byteLength` bounds the buffer, not the size of the
        // resource it came from: a longer external file and the padding of a GLB
        // BIN chunk carry bytes no view may reach.
        let limit = min(try gltf.load(\.buffers, at: bufferView.buffer).byteLength, buffer.count)
        let end = bufferView.byteOffset.addingReportingOverflow(bufferView.byteLength)
        guard bufferView.byteOffset >= 0, bufferView.byteLength >= 0,
              !end.overflow, end.partialValue <= limit else {
            throw VRMError._dataInconsistent(
                "buffer view (offset: \(bufferView.byteOffset), length: \(bufferView.byteLength)) overruns its \(limit) byte buffer"
            )
        }
        return (buffer.subdata(in: bufferView.byteOffset..<end.partialValue), bufferView.byteStride)
    }
}
