import Foundation

extension GLTFEditableDocument {
    /// Appends the default scene of `source` under `parentNode`, wrapped in one
    /// container node, and returns that container's index.
    ///
    /// The whole source document is copied to the end of the arrays it belongs
    /// in and rebased, not only what the chosen scene reaches, so a source of
    /// several scenes costs the size of all of them and draws one. Nothing
    /// already in the target moves, so the extensions that make it a VRM keep
    /// pointing at what they used to.
    ///
    /// The source's own VRM extensions are not copied: this composes props and
    /// clothing onto an avatar, not avatars onto each other. Its materials come
    /// over as they are unless `materials` asks for them to be written as MToon.
    ///
    /// A source of several scenes naming no default one has to be told which
    /// to take, through ``append(_:sceneAt:under:name:transform:materials:)``.
    @discardableResult
    public func append(_ source: GLTFDocument,
                       under parentNode: Int,
                       name: String? = nil,
                       transform: GLTFNodeTransform = .identity,
                       materials: GLTFMaterialConversion = .keep) throws -> Int {
        try append(source, scene: nil, under: parentNode,
                   name: name, transform: transform, materials: materials)
    }

    /// Appends the scene at `sceneIndex` of `source`, for a document that names
    /// no default one or whose default one is not the scene wanted.
    @discardableResult
    public func append(_ source: GLTFDocument,
                       sceneAt sceneIndex: Int,
                       under parentNode: Int,
                       name: String? = nil,
                       transform: GLTFNodeTransform = .identity,
                       materials: GLTFMaterialConversion = .keep) throws -> Int {
        try append(source, scene: sceneIndex, under: parentNode,
                   name: name, transform: transform, materials: materials)
    }

    private func append(_ source: GLTFDocument,
                        scene sceneIndex: Int?,
                        under parentNode: Int,
                        name: String?,
                        transform: GLTFNodeTransform,
                        materials: GLTFMaterialConversion) throws -> Int {
        try transform.validate()
        let sourceJSON = try source.rawJSON()
        try Self.validateAppendable(sourceJSON)
        // Both resolved up front, so a bad index cannot leave an orphaned copy
        // of the whole source behind.
        let roots = try Self.sceneRoots(of: sourceJSON, sceneAt: sceneIndex)
        try requireNode(at: parentNode)

        // What follows can still fail once the merge has begun writing.
        return try atomicallyAppendingBinary {
            let materialBase = json.count(.materials)
            var merger = GLTFMerger(source: source, sourceJSON: sourceJSON, target: self)
            let nodeOffset = try merger.merge()
            if case .mtoon(let style) = materials {
                try convertMaterialsToMToon(at: materialBase..<json.count(.materials), style: style)
            }

            var container = JSONObject()
            container.set("name", name)
            transform.write(into: &container)
            container.set("children", roots.isEmpty ? nil : roots.map { $0 + nodeOffset })

            let index = appendNode(container)
            try addChild(index, to: parentNode)
            return index
        }
    }

    /// The roots of the source scene to copy: the one asked for, or the default
    /// one the document names.
    private static func sceneRoots(of sourceJSON: JSONObject, sceneAt sceneIndex: Int?) throws -> [Int] {
        let scenes = sourceJSON.objects(.scenes)
        guard let index = sceneIndex else {
            return try scenes[GLTFEditableDocument.defaultSceneIndex(of: sourceJSON, of: "source")]
                .ints("nodes") ?? []
        }
        guard scenes.indices.contains(index) else {
            throw VRMError._dataInconsistent(
                "scene index \(index) is out of range for the \(scenes.count) scenes of the source"
            )
        }
        return scenes[index].ints("nodes") ?? []
    }

    /// A merge rebases every index it carries over, so it may only carry over
    /// extensions whose shape it knows. An unknown one is refused, since one
    /// holding indices would come out silently pointing at the wrong thing.
    private static func validateAppendable(_ sourceJSON: JSONObject) throws {
        // VRM 0.x keeps a material's MToon settings in the root extension,
        // which describes the avatar the source is rather than the nodes
        // borrowed out of it. Copying the nodes alone would strip their shading.
        guard sourceJSON.object("extensions")?[GLTFExtension.vrm0.rawValue] == nil else {
            throw VRMError._notSupported(
                "the source is a VRM 0.x model, whose materials are described outside the materials themselves"
            )
        }
        // A root extension describes the document as a whole rather than the
        // nodes borrowed out of it, so it is refused rather than dropped.
        let rootExtensions = sourceJSON.nonVRMRootExtensions()
        guard rootExtensions.isEmpty else {
            throw VRMError._notSupported(
                "the source has the root extension \(rootExtensions.sorted().joined(separator: ", ")), "
                + "whose contents this merge cannot carry over"
            )
        }
        // The document is read for the extensions it carries as well as asked
        // for the ones it declares: an undeclared one would come over with its
        // indices still pointing into the source's own arrays.
        let unsupported = sourceJSON.carriedExtensions()
            .subtracting(GLTFExtension.mergeable)
            // A VRM 1.0 source keeps its materials on the materials, so only
            // what makes it an avatar is dropped.
            .subtracting(GLTFExtension.vrmRoot)
        guard unsupported.isEmpty else {
            throw VRMError._notSupported(
                "the source carries \(unsupported.sorted().joined(separator: ", ")), "
                + "which this merge cannot rebase"
            )
        }
    }
}

/// Copies one glTF document into another, rebasing every index it carries over
/// onto the end of the target's arrays.
private struct GLTFMerger {
    let source: GLTFDocument
    let sourceJSON: JSONObject
    let target: GLTFEditableDocument

    /// Where each source array lands in the target.
    private var base: [GLTFArray: Int] = [:]
    /// Where each source buffer landed in the target's BIN buffer.
    private var bufferOffsets: [Int] = []

    init(source: GLTFDocument, sourceJSON: JSONObject, target: GLTFEditableDocument) {
        self.source = source
        self.sourceJSON = sourceJSON
        self.target = target
    }

    /// Copies the whole source document into the target and returns how far
    /// every source node index moves.
    mutating func merge() throws -> Int {
        for array in Self.rebasedArrays {
            base[array] = target.json.count(array)
        }
        for index in sourceJSON.objects(.buffers).indices {
            bufferOffsets.append(target.appendToBinary(try source.bufferData(at: index)))
        }

        // A buffer view names a slice of a buffer rather than an entry of an
        // array, so it is the one thing rebased by byte offset.
        var bufferViews = try sourceJSON.objects(.bufferViews).map { view -> JSONObject in
            var view = view
            try view.rebaseOntoSingleBuffer(offsets: bufferOffsets)
            return view
        }
        // An image already in a buffer view moves with it; one in a file or a
        // data URI is read into the BIN buffer by ``embeddingImages`` after.
        let images = try GLTFEditableDocument.embeddingImages(
            rebased(.images),
            relativeTo: source.rootDirectory,
            into: &bufferViews,
            viewOffset: offset(of: .bufferViews)
        ) { target.appendToBinary($0) }

        target.json.appendObjects(bufferViews, to: .bufferViews)
        target.json.appendObjects(images, to: .images)
        target.json.appendObjects(rebased(.accessors), to: .accessors)
        target.json.appendObjects(rebased(.samplers), to: .samplers)
        target.json.appendObjects(rebased(.cameras), to: .cameras)
        target.json.appendObjects(rebased(.textures), to: .textures)
        target.json.appendObjects(rebased(.meshes), to: .meshes)
        target.json.appendObjects(rebased(.skins), to: .skins)
        target.json.appendObjects(rebased(.nodes), to: .nodes)
        target.json.appendObjects(rebased(.animations), to: .animations)

        let materials = rebased(.materials)
        target.json.appendObjects(materials, to: .materials)
        try target.appendVRM0MaterialProperties(named: materials.map { $0.string("name") })
        mergeExtensionDeclarations()

        return offset(of: .nodes)
    }

    // MARK: - Rebasing

    /// The arrays a merge copies into, and so the indices it has to rebase.
    private static let rebasedArrays: [GLTFArray] = [
        .bufferViews, .accessors, .samplers, .images, .textures, .materials, .meshes, .skins, .cameras, .nodes,
    ]

    /// How far every index into `array` moves.
    private func offset(of array: GLTFArray) -> Int { base[array] ?? 0 }

    /// Every source entry of `array`, with each index it holds moved to the
    /// end of the target's arrays. What counts as an index is
    /// ``GLTFReferences``'s answer, the same one pruning remaps by.
    private func rebased(_ array: GLTFArray) -> [JSONObject] {
        let base = base
        return sourceJSON.objects(array).map { entry in
            GLTFReferences.rewriting(entry, of: array) { array, index, _ in index + (base[array] ?? 0) }
        }
    }

    // MARK: - Target consistency

    /// An extension the source could not be rendered without stays one the
    /// merged document cannot either, so both lists come over.
    private func mergeExtensionDeclarations() {
        target.declareExtensions(used: Set(sourceJSON.strings("extensionsUsed")).subtracting(GLTFExtension.vrmRoot),
                                 required: Set(sourceJSON.strings("extensionsRequired")).subtracting(GLTFExtension.vrmRoot))
    }
}
