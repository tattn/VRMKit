import Foundation

extension GLTFEditableDocument {
    /// Appends the default scene of `source` under `parentNode`, wrapped in one
    /// container node, and returns that container's index.
    ///
    /// The whole source document is copied to the end of the arrays it belongs
    /// in and rebased, not only what the chosen scene reaches: the scene
    /// decides which of the copied nodes hang under the container, so a source
    /// of several scenes costs the size of all of them and draws one. Nothing
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
        return try atomically {
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
    /// extensions whose shape it knows. An unknown one is refused rather than
    /// copied and hoped about, since the ones holding indices would come out
    /// silently pointing at the wrong thing.
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
        // Below the root, the document is read for the extensions it carries as
        // well as asked for the ones it declares: an undeclared one would come
        // over with its indices still pointing into the source's own arrays.
        let unsupported = sourceJSON.declaredExtensions()
            .union(sourceJSON.nestedExtensions())
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

        var bufferViews = try sourceJSON.objects(.bufferViews).map(rebasedBufferView)
        let images = try GLTFEditableDocument.embeddingImages(
            sourceJSON.objects(.images).map(rebasedImage),
            relativeTo: source.rootDirectory,
            into: &bufferViews,
            viewOffset: offset(of: .bufferViews)
        ) { target.appendToBinary($0) }

        target.json.appendObjects(bufferViews, to: .bufferViews)
        target.json.appendObjects(images, to: .images)
        target.json.appendObjects(sourceJSON.objects(.accessors).map(rebasedAccessor), to: .accessors)
        target.json.appendObjects(sourceJSON.objects(.samplers), to: .samplers)
        target.json.appendObjects(sourceJSON.objects(.cameras), to: .cameras)
        target.json.appendObjects(sourceJSON.objects(.textures).map(rebasedTexture), to: .textures)
        target.json.appendObjects(sourceJSON.objects(.meshes).map(rebasedMesh), to: .meshes)
        target.json.appendObjects(sourceJSON.objects(.skins).map(rebasedSkin), to: .skins)
        target.json.appendObjects(sourceJSON.objects(.nodes).map(rebasedNode), to: .nodes)
        target.json.appendObjects(sourceJSON.objects(.animations).map(rebasedAnimation), to: .animations)

        let materials = sourceJSON.objects(.materials).map(rebasedMaterial)
        target.json.appendObjects(materials, to: .materials)
        target.appendVRM0MaterialProperties(named: materials.map { $0.string("name") })
        mergeExtensionDeclarations()
        // The binary has stopped growing, so its `buffers` entry is written once.
        target.writeSingleBufferEntry()

        return offset(of: .nodes)
    }

    // MARK: - Rebasing

    /// The arrays a merge copies into, and so the indices it has to rebase.
    private static let rebasedArrays: [GLTFArray] = [
        .bufferViews, .accessors, .samplers, .images, .textures, .materials, .meshes, .skins, .cameras, .nodes,
    ]

    /// How far every index into `array` moves.
    private func offset(of array: GLTFArray) -> Int { base[array] ?? 0 }

    private func rebasedBufferView(_ view: JSONObject) throws -> JSONObject {
        var view = view
        try view.rebaseOntoSingleBuffer(offsets: bufferOffsets)
        return view
    }

    private func rebasedAccessor(_ accessor: JSONObject) -> JSONObject {
        var accessor = accessor
        accessor.rebase("bufferView", by: offset(of: .bufferViews))
        accessor.withObject("sparse") { sparse in
            sparse.withObject("indices") { $0.rebase("bufferView", by: offset(of: .bufferViews)) }
            sparse.withObject("values") { $0.rebase("bufferView", by: offset(of: .bufferViews)) }
        }
        return accessor
    }

    /// An image already in a buffer view moves with it; one in a file or a
    /// data URI is read into the BIN buffer by ``embeddingImages`` after.
    private func rebasedImage(_ image: JSONObject) -> JSONObject {
        var image = image
        image.rebase("bufferView", by: offset(of: .bufferViews))
        return image
    }

    private func rebasedTexture(_ texture: JSONObject) -> JSONObject {
        var texture = texture
        let imageOffset = offset(of: .images)
        texture.rebase("source", by: imageOffset)
        texture.rebase("sampler", by: offset(of: .samplers))
        // KHR_texture_basisu and EXT_texture_webp name an alternative image
        // the same way the texture itself does.
        texture.withObject("extensions") { extensions in
            for name in [GLTFExtension.textureBasisu, .textureWebP] {
                extensions.withObject(name.rawValue) { $0.rebase("source", by: imageOffset) }
            }
        }
        return texture
    }

    /// Rebases the texture references of one material: the slots glTF defines
    /// and those of the extensions ``validateAppendable`` allowed. A key ending
    /// in `Texture` under `extras` is the document's own field rather than a
    /// texture reference, so nothing else is walked.
    private func rebasedMaterial(_ material: JSONObject) -> JSONObject {
        var material = rebasedTextureSlots(material)
        material.withObject("pbrMetallicRoughness") { $0 = rebasedTextureSlots($0) }
        material.withObject("extensions") { extensions in
            for name in Array(extensions.keys) where GLTFExtension.mergeable.contains(name) {
                extensions.withObject(name) { $0 = rebasedTextureSlots($0) }
            }
        }
        return material
    }

    /// Rebases every `textureInfo` directly under `object`, which glTF and the
    /// material extensions it defines all name with a key ending in `Texture`.
    private func rebasedTextureSlots(_ object: JSONObject) -> JSONObject {
        var object = object
        for key in Array(object.keys) where key.hasSuffix("Texture") {
            object.withObject(key) { $0.rebase("index", by: offset(of: .textures)) }
        }
        return object
    }

    private func rebasedMesh(_ mesh: JSONObject) -> JSONObject {
        var mesh = mesh
        mesh.mapObjects("primitives") { primitive in
            var primitive = primitive
            primitive.rebase("indices", by: offset(of: .accessors))
            primitive.rebase("material", by: offset(of: .materials))
            primitive.withObject("attributes") { $0 = rebasedAttributes($0) }
            if let targets = primitive["targets"] as? [JSONObject] {
                primitive["targets"] = targets.map(rebasedAttributes)
            }
            return primitive
        }
        return mesh
    }

    /// Every attribute names an accessor, so the object is rebased by value.
    private func rebasedAttributes(_ attributes: JSONObject) -> JSONObject {
        let accessorOffset = offset(of: .accessors)
        return attributes.mapValues { value in
            numericIndexValue(value).map { $0 + accessorOffset } ?? value
        }
    }

    private func rebasedSkin(_ skin: JSONObject) -> JSONObject {
        var skin = skin
        skin.rebase("inverseBindMatrices", by: offset(of: .accessors))
        skin.rebase("skeleton", by: offset(of: .nodes))
        skin.rebaseAll("joints", by: offset(of: .nodes))
        return skin
    }

    private func rebasedNode(_ node: JSONObject) -> JSONObject {
        var node = node
        node.rebaseAll("children", by: offset(of: .nodes))
        node.rebase("mesh", by: offset(of: .meshes))
        node.rebase("skin", by: offset(of: .skins))
        node.rebase("camera", by: offset(of: .cameras))
        node.withObject("extensions") { extensions in
            extensions.withObject(GLTFExtension.nodeConstraint.rawValue) { nodeConstraint in
                nodeConstraint.withObject("constraint") { constraint in
                    for key in Array(constraint.keys) {
                        constraint.withObject(key) { $0.rebase("source", by: offset(of: .nodes)) }
                    }
                }
            }
        }
        return node
    }

    private func rebasedAnimation(_ animation: JSONObject) -> JSONObject {
        var animation = animation
        animation.mapObjects("channels") { channel in
            var channel = channel
            channel.withObject("target") { $0.rebase("node", by: offset(of: .nodes)) }
            return channel
        }
        animation.mapObjects("samplers") { sampler in
            var sampler = sampler
            sampler.rebase("input", by: offset(of: .accessors))
            sampler.rebase("output", by: offset(of: .accessors))
            return sampler
        }
        return animation
    }

    // MARK: - Target consistency

    /// An extension the source could not be rendered without stays one the
    /// merged document cannot either, so both lists come over.
    private func mergeExtensionDeclarations() {
        target.declareExtensions(used: Set(sourceJSON.strings("extensionsUsed")).subtracting(GLTFExtension.vrmRoot),
                                 required: Set(sourceJSON.strings("extensionsRequired")).subtracting(GLTFExtension.vrmRoot))
    }
}
