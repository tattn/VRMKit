import Foundation

/// A parsed glTF asset together with the context needed to resolve its binary
/// resources (the GLB BIN chunk, external files and data URIs), so that they
/// stay resolvable after loading, e.g. for lazily decoded animation accessors.
public final class GLTFDocument: Sendable {
    public let gltf: GLTF
    /// GLB BIN chunk (chunk 1), when the document came from a GLB container.
    package let binaryBuffer: Data?
    /// Base directory for external buffer / image URIs.
    package let rootDirectory: URL?
    /// The glTF JSON as it was written, when the document was loaded rather
    /// than built from an already-decoded ``GLTF``. Editing re-parses it so
    /// that the fields ``GLTF`` does not model survive a rewrite.
    package let jsonSource: Data?

    /// Decoded buffers, keyed by buffer index: resolving one re-reads an external
    /// file or base64-decodes a whole data URI. Buffer views are not cached, since
    /// keeping them would hold the file's bytes a second time. Locked because a
    /// document is shared between threads.
    private let buffers = Locked<[Int: Data]>([:])

    package init(gltf: GLTF, binaryBuffer: Data?, rootDirectory: URL?, jsonSource: Data? = nil) {
        self.gltf = gltf
        self.binaryBuffer = binaryBuffer
        self.rootDirectory = rootDirectory.map(Self.directoryURL)
        self.jsonSource = jsonSource
    }

    /// A base a relative `uri` resolves inside rather than beside: without a
    /// trailing slash, resolving against it replaces its last segment.
    private static func directoryURL(_ url: URL) -> URL {
        url.hasDirectoryPath ? url : url.appendingPathComponent("")
    }

    /// Wraps an already-parsed GLB container.
    public convenience init(binary: BinaryGLTF, rootDirectory: URL? = nil) {
        self.init(gltf: binary.jsonData,
                  binaryBuffer: binary.binaryBuffer,
                  rootDirectory: rootDirectory,
                  jsonSource: binary.jsonChunk)
    }

    /// Wraps an already-decoded JSON glTF whose resources are external files or
    /// data URIs resolved against `rootDirectory`.
    public convenience init(gltf: GLTF, rootDirectory: URL? = nil) {
        self.init(gltf: gltf, binaryBuffer: nil, rootDirectory: rootDirectory)
    }

    /// Parses in-memory glTF data, sniffing the GLB magic to pick the container
    /// format. `rootDirectory` is the base directory for external resources.
    public convenience init(data: Data, rootDirectory: URL? = nil) throws {
        if BinaryGLTF.isGLB(data) {
            self.init(binary: try BinaryGLTF(data: data), rootDirectory: rootDirectory)
            return
        }
        let gltf = try JSONDecoder().decode(GLTF.self, from: data)
        try gltf.validateSupportedAssetVersion()
        self.init(gltf: gltf, binaryBuffer: nil, rootDirectory: rootDirectory, jsonSource: data)
    }

    /// Loads a `.glb` / `.gltf` file. External resources resolve relative to
    /// the file's directory.
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
    /// The glTF JSON as an editable object tree.
    ///
    /// A document that was loaded keeps its JSON verbatim, so nothing outside the
    /// typed model is lost. One built from an already-decoded ``GLTF`` is
    /// re-encoded from that model, which carries only the fields VRMKit models.
    func rawJSON() throws -> JSONObject {
        if let jsonSource {
            return try JSONValue(parsing: jsonSource).objectValue
                ??? ._dataInconsistent("the glTF JSON is not an object")
        }
        return try JSONValue(encoding: gltf).objectValue
            ??? ._dataInconsistent("the glTF JSON is not an object")
    }

    func bufferData(at index: Int) throws -> Data {
        if let cached = buffers.withLock({ $0[index] }) { return cached }
        let gltfBuffer = try gltf.load(\.buffers, at: index)
        // In a GLB only buffer 0 may omit its URI and refer to the BIN chunk;
        // treating every URI-less buffer as the BIN chunk would alias them.
        guard gltfBuffer.uri != nil || index == 0 else {
            throw VRMError._dataInconsistent("only the first glTF buffer may refer to the GLB BIN chunk")
        }
        // Read outside the lock, rather than hold it across a file read.
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
        // The resource bounds a view, not the `byteLength` the buffer declares:
        // UniVRM 0.x appends a model's thumbnail past it without updating it.
        let end = bufferView.byteOffset.addingReportingOverflow(bufferView.byteLength)
        guard bufferView.byteOffset >= 0, bufferView.byteLength >= 0,
              !end.overflow, end.partialValue <= buffer.count else {
            throw VRMError._dataInconsistent(
                "buffer view (offset: \(bufferView.byteOffset), length: \(bufferView.byteLength)) "
                + "overruns its \(buffer.count) byte buffer"
            )
        }
        // A slice, not a copy: the attributes of an interleaved view each read
        // their own elements out of it.
        let startIndex = buffer.startIndex + bufferView.byteOffset
        return (buffer[startIndex..<startIndex + bufferView.byteLength], bufferView.byteStride)
    }
}
