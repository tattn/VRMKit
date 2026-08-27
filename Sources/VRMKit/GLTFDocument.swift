import Foundation

/// A parsed glTF asset together with the context its binary resources resolve
/// against: the GLB BIN chunk, external files and data URIs. They stay resolvable
/// after loading, for lazily decoded animation accessors among others.
public final class GLTFDocument: Sendable {
    public let gltf: GLTF
    /// GLB BIN chunk (chunk 1), when the document came from a GLB container.
    package let binaryBuffer: Data?
    /// Base directory for external buffer / image URIs.
    package let rootDirectory: URL?
    /// The glTF JSON as it was parsed, nil for a document built from an already-decoded
    /// ``GLTF``. Editing reads it so that what ``GLTF`` does not model survives a rewrite.
    package let jsonRoot: JSONObject?

    /// Decoded buffers, keyed by buffer index: resolving one re-reads an external file or
    /// base64-decodes a whole data URI. Buffer views are not cached, since that would hold
    /// the file's bytes a second time.
    private let buffers = Locked<[Int: Data]>([:])

    package init(gltf: GLTF, binaryBuffer: Data?, rootDirectory: URL?, jsonRoot: JSONObject? = nil) {
        self.gltf = gltf
        self.binaryBuffer = binaryBuffer
        self.rootDirectory = rootDirectory.map(Self.directoryURL)
        self.jsonRoot = jsonRoot
    }

    /// Without a trailing slash, resolving a relative `uri` against a directory would
    /// replace its last segment rather than descend into it.
    private static func directoryURL(_ url: URL) -> URL {
        url.hasDirectoryPath ? url : url.appendingPathComponent("")
    }

    /// Wraps an already-parsed GLB container.
    public convenience init(binary: BinaryGLTF, rootDirectory: URL? = nil) {
        self.init(gltf: binary.gltf,
                  binaryBuffer: binary.binaryBuffer,
                  rootDirectory: rootDirectory,
                  jsonRoot: binary.jsonTree.objectValue)
    }

    /// Wraps an already-decoded JSON glTF whose resources are external files or
    /// data URIs resolved against `rootDirectory`.
    public convenience init(gltf: GLTF, rootDirectory: URL? = nil) {
        self.init(gltf: gltf, binaryBuffer: nil, rootDirectory: rootDirectory)
    }

    /// Parses in-memory glTF data, sniffing the GLB magic to pick the container format.
    public convenience init(data: Data, rootDirectory: URL? = nil) throws {
        if BinaryGLTF.isGLB(data) {
            self.init(binary: try BinaryGLTF(data: data), rootDirectory: rootDirectory)
            return
        }
        let tree = try JSONValue(parsing: data)
        let gltf = try tree.decode(GLTF.self)
        try gltf.validateSupportedAssetVersion()
        self.init(gltf: gltf, binaryBuffer: nil, rootDirectory: rootDirectory, jsonRoot: tree.objectValue)
    }

    /// Loads a `.glb` / `.gltf` file. External resources resolve relative to its directory.
    public convenience init(withURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url), rootDirectory: url.deletingLastPathComponent())
    }

    /// Loads a bundled glTF resource.
    public convenience init(named name: String, in bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            throw URLError(.fileDoesNotExist)
        }
        try self.init(withURL: url)
    }
}

package extension GLTFDocument {
    /// The glTF JSON as an editable object tree. A loaded document keeps its JSON whole;
    /// one built from a ``GLTF`` is re-encoded from it, carrying only what VRMKit models.
    func rawJSON() throws -> JSONObject {
        if let jsonRoot { return jsonRoot }
        return try JSONValue(encoding: gltf).objectValue
            ??? ._dataInconsistent("the glTF JSON is not an object")
    }

    func bufferData(at index: Int) throws -> Data {
        if let cached = buffers.withLock({ $0[index] }) { return cached }
        let gltfBuffer = try gltf.load(\.buffers, at: index)
        // In a GLB only buffer 0 may omit its URI and refer to the BIN chunk.
        guard gltfBuffer.uri != nil || index == 0 else {
            throw VRMError._dataInconsistent("only the first glTF buffer may refer to the GLB BIN chunk")
        }
        // Read outside the lock rather than hold it across a file read.
        let data = try Data(buffer: gltfBuffer, relativeTo: rootDirectory, binaryBuffer: binaryBuffer)
        buffers.withLock { $0[index] = data }
        return data
    }

    var bufferViewProvider: BufferViewProvider {
        { [self] index in
            let (data, stride) = try bufferViewData(at: index)
            return (bufferView: data, stride: stride)
        }
    }

    func bufferViewData(at index: Int) throws -> (data: Data, stride: Int?) {
        let bufferView = try gltf.load(\.bufferViews, at: index)
        let buffer = try bufferData(at: bufferView.buffer)
        // The resource bounds a view, not the buffer's `byteLength`: UniVRM 0.x
        // appends a model's thumbnail past it without updating it.
        let end = bufferView.byteOffset.addingReportingOverflow(bufferView.byteLength)
        guard bufferView.byteOffset >= 0, bufferView.byteLength >= 0,
              !end.overflow, end.partialValue <= buffer.count else {
            throw VRMError._dataInconsistent(
                "buffer view (offset: \(bufferView.byteOffset), length: \(bufferView.byteLength)) "
                + "overruns its \(buffer.count) byte buffer"
            )
        }
        // A slice, not a copy: the attributes of an interleaved view each read their own elements.
        let startIndex = buffer.startIndex + bufferView.byteOffset
        return (buffer[startIndex..<startIndex + bufferView.byteLength], bufferView.byteStride)
    }
}
