import Foundation

/// A glTF document that can be edited and written back out as a GLB.
///
/// Editing works on the JSON as it was parsed, not on ``GLTF``: the typed model
/// covers only the fields VRMKit reads, so encoding it back out would drop
/// every extension, `extras` and vendor field it does not know. An edit
/// therefore changes nothing but what it was asked to.
///
/// Loading pulls the binary resources into a single BIN buffer, so a `.gltf`
/// with external files or data URIs saves as one self-contained GLB.
public final class GLTFEditableDocument {
    var json: JSONObject

    /// The single buffer every buffer view indexes into. Its JSON `byteLength`
    /// is derived when a typed or serialized snapshot is requested, so edits
    /// cannot leave two copies of the same state out of sync.
    var binary: Data

    /// An empty glTF 2.0 document, where an asset built from vertex data rather
    /// than read from a file starts. It holds nothing at all, not even a scene:
    /// adding the first node is what gives it one.
    public init() {
        json = ["asset": ["version": "2.0"]]
        binary = Data()
    }

    /// Loads GLB or JSON glTF data. External resources of a `.gltf` resolve
    /// against `rootDirectory`, as they do for ``GLTFDocument``.
    public convenience init(data: Data, rootDirectory: URL? = nil) throws {
        try self.init(document: GLTFDocument(data: data, rootDirectory: rootDirectory))
    }

    /// Takes over an already-loaded document.
    public init(document: GLTFDocument) throws {
        var json = try document.rawJSON()
        binary = try Self.embedResources(of: document, into: &json)
        self.json = json
    }

    /// The document as the typed model, decoded from its JSON on each call.
    public func typed() throws -> GLTF {
        try jsonSnapshot().decode(GLTF.self)
    }

    /// Writes the document as a GLB: the JSON chunk, then the BIN chunk.
    public func serialize() throws -> Data {
        var jsonChunk = try JSONSerialization.data(withJSONObject: jsonSnapshot(),
                                                   options: [.sortedKeys, .withoutEscapingSlashes])
        jsonChunk.padToFourByteBoundary(with: 0x20)
        // Padded as it is appended, rather than in a copy of the whole buffer.
        let binaryPadding = binary.isEmpty ? 0 : binary.fourByteBoundaryPadding
        let binaryLength = binary.count + binaryPadding

        let length = BinaryGLTF.headerLength + BinaryGLTF.chunkHeaderLength + jsonChunk.count
            + (binaryLength == 0 ? 0 : BinaryGLTF.chunkHeaderLength + binaryLength)
        guard length <= UInt32.max else {
            throw VRMError._dataInconsistent("a GLB holds at most 4 GB, and this document is \(length) bytes")
        }

        var glb = Data(capacity: length)
        glb.appendUInt32(BinaryGLTF.magic)
        glb.appendUInt32(GLTF.Version.two.rawValue)
        glb.appendUInt32(UInt32(length))
        glb.appendUInt32(UInt32(jsonChunk.count))
        glb.appendUInt32(BinaryGLTF.ChunkType.json.rawValue)
        glb.append(jsonChunk)
        if binaryLength != 0 {
            glb.appendUInt32(UInt32(binaryLength))
            glb.appendUInt32(BinaryGLTF.ChunkType.bin.rawValue)
            glb.append(binary)
            glb.append(contentsOf: repeatElement(0, count: binaryPadding))
        }
        return glb
    }
}

extension GLTFEditableDocument {
    func appendToBinary(_ data: Data) -> Int {
        binary.appendAligned(data)
    }

    /// Adds to the lists a document has to carry for every extension it names.
    /// `required` is the subset of `used` a renderer cannot do without.
    func declareExtensions(used: Set<String>, required: Set<String> = []) {
        declare(used.union(required), in: "extensionsUsed")
        declare(required, in: "extensionsRequired")
    }

    /// The root `extensions` object, empty for a document carrying none.
    var rootExtensions: JSONObject { json.object("extensions") ?? [:] }

    /// The object of the root extension `name`, or nil when the document
    /// carries none. One that is there but is not an object is refused rather
    /// than read as absent, since writing would throw away what it holds.
    func rootExtensionObject(_ name: String) throws -> JSONObject? {
        try rootExtensions.requiredObject(name, of: "extensions")
    }

    /// Writes through to the object of the root extension `name`, leaving every
    /// other field of it as it was. A document carrying no such extension is
    /// given one and declares it; one that already carried it is left declaring
    /// what it declared.
    @discardableResult
    func updateRootExtension<T>(_ name: String, _ body: (inout JSONObject) throws -> T) throws -> T {
        let existing = try rootExtensionObject(name)
        var extensionObject = existing ?? [:]
        let result = try body(&extensionObject)
        var extensions = rootExtensions
        extensions[name] = extensionObject
        json["extensions"] = extensions
        if existing == nil {
            declareExtensions(used: [name])
        }
        return result
    }

    private func declare(_ names: Set<String>, in key: String) {
        guard !names.isEmpty else { return }
        json[key] = Set(json.strings(key)).union(names).sorted()
    }

    /// The editable JSON with its one derived buffer entry materialized.
    private func jsonSnapshot() -> JSONObject {
        var snapshot = json
        guard !binary.isEmpty else {
            snapshot.removeValue(forKey: GLTFArray.buffers.rawValue)
            return snapshot
        }
        var buffer = snapshot.objects(.buffers).first ?? [:]
        buffer.removeValue(forKey: "uri")
        buffer["byteLength"] = binary.count
        snapshot[.buffers] = [buffer]
        return snapshot
    }

    /// Runs `body`, which may only append to the BIN buffer, so that it either
    /// takes effect whole or not at all.
    ///
    /// The buffer is rolled back by its length rather than by a saved copy,
    /// which is why `body` may not shorten it: a second reference would make
    /// the first append copy however many megabytes it holds. An edit that
    /// relays the buffer out builds the new one and swaps it in once nothing
    /// can throw, as ``prune()`` does.
    func atomicallyAppendingBinary<T>(_ body: () throws -> T) throws -> T {
        let savedJSON = json
        let savedBinaryCount = binary.count
        do {
            let result = try body()
            assert(binary.count >= savedBinaryCount, "an atomic edit may only append to the BIN buffer")
            return result
        } catch {
            assert(binary.count >= savedBinaryCount, "an atomic edit may only append to the BIN buffer")
            json = savedJSON
            binary.removeLast(binary.count - savedBinaryCount)
            throw error
        }
    }

    /// Pulls every resource into the BIN buffer so the result stands on its
    /// own as a GLB: external files and data URIs are read in, views rebased.
    private static func embedResources(of document: GLTFDocument, into json: inout JSONObject) throws -> Data {
        try validateRelayout(of: json)
        var binary = Data()
        var offsets: [Int] = []
        for index in json.objects(.buffers).indices {
            // The whole resolved buffer, not the `byteLength` the document
            // declares: some exporters write a length shorter than their views.
            offsets.append(binary.appendAligned(try document.bufferData(at: index)))
        }

        var views = try json.objects(.bufferViews).map { view -> JSONObject in
            var view = view
            try view.rebaseOntoSingleBuffer(offsets: offsets)
            // A meshopt view carries a second slice of the same buffer.
            try view.withObject("extensions") { extensions in
                try extensions.withObject(GLTFExtension.meshoptCompression.rawValue) { meshopt in
                    try meshopt.rebaseOntoSingleBuffer(offsets: offsets)
                }
            }
            return view
        }

        let images = try embeddingImages(json.objects(.images),
                                         relativeTo: document.rootDirectory,
                                         into: &views) { binary.appendAligned($0) }
        // A document that had no such array is left without one.
        if !images.isEmpty { json[.images] = images }
        if !views.isEmpty { json[.bufferViews] = views }
        return binary
    }

    /// Merging several buffers into the one a GLB holds moves byte offsets and
    /// drops all but one `buffers` entry, and an extension this does not know
    /// may name a buffer and an offset itself, the way
    /// `EXT_meshopt_compression` does, so such a document is refused.
    ///
    /// A document already on one buffer keeps every offset it had, whatever it
    /// declares.
    private static func validateRelayout(of json: JSONObject) throws {
        let buffers = json.count(.buffers)
        guard buffers > 1 else { return }
        let unknown = json.carriedExtensions().subtracting(GLTFExtension.known)
        guard unknown.isEmpty else {
            throw VRMError._notSupported(
                "the document carries \(unknown.sorted().joined(separator: ", ")) and holds \(buffers) "
                + "buffers, which merging into the one a GLB holds would move"
            )
        }
    }

    /// Reads every image kept in a file or a data URI into the BIN buffer,
    /// adding a buffer view for each: a GLB has nowhere else to keep one.
    /// `viewOffset` is where `views` lands in the document the images end up
    /// in, so that loading and merging can share the one mapping.
    static func embeddingImages(_ images: [JSONObject],
                                relativeTo rootDirectory: URL?,
                                into views: inout [JSONObject],
                                viewOffset: Int = 0,
                                appendingWith append: (Data) -> Int) throws -> [JSONObject] {
        try images.map { image in
            var image = image
            guard let uri = image.string("uri") else { return image }
            let data = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
            views.append(["buffer": 0, "byteOffset": append(data), "byteLength": data.count])
            image.removeValue(forKey: "uri")
            image["bufferView"] = viewOffset + views.count - 1
            image["mimeType"] = try image.string("mimeType") ?? mimeType(forURI: uri, data: data)
            return image
        }
    }

    /// The type an embedded image is named by, from the URI it was read from
    /// or, failing that, from the bytes themselves.
    private static func mimeType(forURI uri: String, data: Data) throws -> String {
        if uri.hasPrefix("data:") {
            let body = uri.dropFirst("data:".count)
            if let separator = body.firstIndex(where: { $0 == ";" || $0 == "," }), separator > body.startIndex {
                return String(body[..<separator])
            }
        }
        switch (uri as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ktx2": return "image/ktx2"
        default: break
        }
        return try data.imageMediaType
            ??? ._dataInconsistent("the image at \"\(uri)\" is of no format a GLB can name")
    }
}
