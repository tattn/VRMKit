import Foundation

extension GLTFEditableDocument {
    /// Appends the default scene of `source` under `parentNode`, wrapped in one
    /// container node, and returns that container's index.
    ///
    /// Only what the chosen scene draws is copied, and nothing already in the target moves,
    /// so the extensions that make it a VRM keep pointing at what they used to. The source's
    /// own VRM extensions are not copied: this composes props and clothing onto an avatar,
    /// not avatars onto each other.
    @discardableResult
    public mutating func append(_ source: GLTFDocument,
                       under parentNode: GLTFNodeIndex,
                       name: String? = nil,
                       transform: GLTFNodeTransform = .identity,
                       materials: GLTFMaterialConversion = .keep) throws -> GLTFNodeIndex {
        try GLTFNodeIndex(append(source, scene: nil, under: parentNode.rawValue,
                                 name: name, transform: transform, materials: materials))
    }

    /// Appends the scene at `sceneIndex` of `source`, for a document that names
    /// no default one or whose default one is not the scene wanted.
    @discardableResult
    public mutating func append(_ source: GLTFDocument,
                       sceneAt sceneIndex: GLTFSceneIndex,
                       under parentNode: GLTFNodeIndex,
                       name: String? = nil,
                       transform: GLTFNodeTransform = .identity,
                       materials: GLTFMaterialConversion = .keep) throws -> GLTFNodeIndex {
        try GLTFNodeIndex(append(source, scene: sceneIndex.rawValue, under: parentNode.rawValue,
                                 name: name, transform: transform, materials: materials))
    }

    private mutating func append(_ source: GLTFDocument,
                        scene sceneIndex: Int?,
                        under parentNode: Int,
                        name: String?,
                        transform: GLTFNodeTransform,
                        materials: GLTFMaterialConversion) throws -> Int {
        try transform.validate()
        let sourceJSON = try source.rawJSON()
        try Self.validateAppendable(sourceJSON)
        // Both resolved up front, so a bad index cannot leave an orphaned copy of
        // the whole source behind.
        let scene = try Self.sceneIndex(of: sourceJSON, sceneAt: sceneIndex)
        try requireNode(at: parentNode)

        let trimmed = try Self.trimming(source, toSceneAt: scene)
        let roots = trimmed.json.objects(.scenes).first?.ints("nodes") ?? []

        return try atomically { document in
            let materialBase = document.json.count(.materials)
            var merger = GLTFMerger(source: trimmed)
            let nodeOffset = try merger.merge(into: &document)
            if case .mtoon(let style) = materials {
                let merged = (materialBase..<document.json.count(.materials)).map { GLTFMaterialIndex($0) }
                try document.convertMaterialsToMToon(at: merged, style: style)
            }

            var container = JSONObject()
            container.set("name", name)
            transform.write(into: &container)
            container.set("children", roots.isEmpty ? nil : .numbers(roots.map { $0 + nodeOffset }))

            let index = document.appendNode(container)
            try document.addChild(index, to: parentNode)
            return index
        }
    }

    /// The source scene to copy: the one asked for, or the default one the
    /// document names.
    private static func sceneIndex(of sourceJSON: JSONObject, sceneAt sceneIndex: Int?) throws -> Int {
        guard let index = sceneIndex else {
            return try GLTFEditableDocument.defaultSceneIndex(of: sourceJSON, of: "source")
        }
        let scenes = sourceJSON.count(.scenes)
        guard index >= 0, index < scenes else {
            throw VRMError._dataInconsistent(
                "scene index \(index) is out of range for the \(scenes) scenes of the source"
            )
        }
        return index
    }

    /// The source cut down to the one scene being appended, with its resources pulled into
    /// a single buffer the way the target's already are. What makes it an avatar is dropped
    /// first, so pruning does not hold on to every node a humanoid names.
    private static func trimming(_ source: GLTFDocument, toSceneAt index: Int) throws -> GLTFEditableDocument {
        var trimmed = try GLTFEditableDocument(document: source)
        trimmed.json.setObjects([trimmed.json.objects(.scenes)[index]], for: .scenes)
        trimmed.json["scene"] = 0
        var extensions = trimmed.json.object("extensions") ?? [:]
        for name in GLTFExtension.vrmRoot {
            extensions.removeValue(forKey: name)
        }
        trimmed.json.set("extensions", extensions.isEmpty ? nil : extensions)
        try trimmed.prune()
        return trimmed
    }

    /// A merge rebases every index it carries over, so it may only carry over
    /// extensions whose shape it knows. An unknown one is refused, since one
    /// holding indices would come out silently pointing at the wrong thing.
    private static func validateAppendable(_ sourceJSON: JSONObject) throws {
        // VRM 0.x keeps a material's MToon settings in the root extension, so
        // copying the nodes alone would strip their shading.
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
        // Read for the extensions it carries as well as the ones it declares: an
        // undeclared one would come over with its indices still pointing into the
        // source's own arrays.
        let unsupported = sourceJSON.carriedExtensions()
            .subtracting(GLTFExtension.mergeable)
            .subtracting(GLTFExtension.vrmRoot)
        guard unsupported.isEmpty else {
            throw VRMError._notSupported(
                "the source carries \(unsupported.sorted().joined(separator: ", ")), "
                + "which this merge cannot rebase"
            )
        }
    }
}

/// Copies one glTF document into another, rebasing every index it carries over onto the
/// end of the target's arrays. The source arrives as a single buffer with every resource
/// in it, so what is left to move is indices and one byte offset.
private struct GLTFMerger {
    let source: GLTFEditableDocument

    private var sourceJSON: JSONObject { source.json }
    /// Where each source array lands in the target.
    private var base: [GLTFArray: Int] = [:]

    init(source: GLTFEditableDocument) {
        self.source = source
    }

    /// Copies the source document into `target` and returns how far every
    /// source node index moves.
    mutating func merge(into target: inout GLTFEditableDocument) throws -> Int {
        for array in Self.rebasedArrays {
            base[array] = target.json.count(array)
        }
        // A buffer view names a slice of a buffer rather than an entry of an
        // array, so it is the one thing rebased by byte offset.
        let bufferOffset = target.appendToBinary(source.binary)
        let bufferViews = try sourceJSON.objects(.bufferViews).map { view -> JSONObject in
            var view = view
            try view.rebaseOntoSingleBuffer(offsets: [bufferOffset])
            return view
        }

        target.json.appendObjects(bufferViews, to: .bufferViews)
        target.json.appendObjects(rebased(.images), to: .images)
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
        mergeExtensionDeclarations(into: &target)

        return offset(of: .nodes)
    }

    // MARK: - Rebasing

    /// The arrays a merge copies into, and so the indices it has to rebase.
    private static let rebasedArrays: [GLTFArray] = [
        .bufferViews, .accessors, .samplers, .images, .textures, .materials, .meshes, .skins, .cameras, .nodes,
    ]

    /// How far every index into `array` moves.
    private mutating func offset(of array: GLTFArray) -> Int { base[array] ?? 0 }

    /// Every source entry of `array`, with each index it holds moved to the end
    /// of the target's arrays. ``GLTFReferences`` decides what counts as an index.
    private mutating func rebased(_ array: GLTFArray) -> [JSONObject] {
        let base = base
        return sourceJSON.objects(array).map { entry in
            GLTFReferences.rewriting(entry, of: array) { array, index, _ in index + (base[array] ?? 0) }
        }
    }

    // MARK: - Target consistency

    /// An extension the source could not be rendered without stays one the
    /// merged document cannot either, so both lists come over.
    private func mergeExtensionDeclarations(into target: inout GLTFEditableDocument) {
        target.declareExtensions(used: Set(sourceJSON.strings("extensionsUsed")).subtracting(GLTFExtension.vrmRoot),
                                 required: Set(sourceJSON.strings("extensionsRequired")).subtracting(GLTFExtension.vrmRoot))
    }
}
