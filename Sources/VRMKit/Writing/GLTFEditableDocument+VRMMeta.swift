import Foundation

extension GLTFEditableDocument {
    /// Replaces the image the model shows itself by, with a PNG or a JPEG. VRM 0.x
    /// lists a thumbnail as a texture and 1.0 as an image, and this writes whichever
    /// the document keeps.
    ///
    /// VRM 1.0 requires a square thumbnail, so one that is not square is refused.
    /// The thumbnail this replaces is left where it is, for ``prune()`` to work out:
    /// a material may sample the same image.
    public mutating func setVRMThumbnail(_ image: Data) throws {
        try atomically { document in
            let version = try document.vrmSpecVersion()
            let mediaType = try image.imageMediaType
                ??? ._notSupported("a VRM thumbnail is a PNG or a JPEG, and this image is neither")
            let decoded = try image.decodedImage
                ??? ._dataInconsistent("the thumbnail is not an image this platform decodes")
            if version == .v1 {
                guard decoded.width == decoded.height else {
                    throw VRMError._dataInconsistent(
                        "a VRM 1.0 thumbnail is square, and this one is \(decoded.width)x\(decoded.height)"
                    )
                }
            }

            switch version {
            case .v0:
                let texture = document.appendTexture(image, mediaType: mediaType)
                try document.updateVRMMeta(version) { $0["texture"] = .int(texture) }
            case .v1:
                let imageIndex = document.appendImage(image, mediaType: mediaType)
                try document.updateVRMMeta(version) { $0["thumbnailImage"] = .int(imageIndex) }
            }
        }
    }

    /// Sets the name the model goes by, which VRM 0.x calls its title and
    /// VRM 1.0 its name.
    ///
    /// VRM 1.0 requires a name of at least one character, so an empty one is
    /// refused. VRM 0.x puts no such length on its title.
    public mutating func setVRMName(_ name: String) throws {
        let version = try vrmSpecVersion()
        if version == .v1 {
            guard !name.isEmpty else {
                throw VRMError._dataInconsistent("a VRM 1.0 model's name is at least one character long")
            }
        }
        try updateVRMMeta(version) { meta in
            switch version {
            case .v0: meta["title"] = .string(name)
            case .v1: meta["name"] = .string(name)
            }
        }
    }

    /// Sets who made the model. VRM 1.0 lists its authors one by one; VRM 0.x has
    /// the single `meta.author` line, so several names are joined into it.
    ///
    /// VRM 1.0 requires at least one author, each of at least one character, so an
    /// empty list or an empty name is refused.
    public mutating func setVRMAuthors(_ authors: [String]) throws {
        let version = try vrmSpecVersion()
        if version == .v1 {
            guard !authors.isEmpty, authors.allSatisfy({ !$0.isEmpty }) else {
                throw VRMError._dataInconsistent(
                    "a VRM 1.0 model names at least one author, each of at least one character"
                )
            }
        }
        try updateVRMMeta(version) { meta in
            switch version {
            case .v0: meta["author"] = .string(authors.joined(separator: ", "))
            case .v1: meta["authors"] = .strings(authors)
            }
        }
    }

    /// Writes through to the meta of the VRM extension `version` names, leaving
    /// every other field of it as it was. A model whose meta is not an object is
    /// refused rather than given a fresh one in its place.
    private mutating func updateVRMMeta(_ version: VRMSpecVersion, _ body: (inout JSONObject) -> Void) throws {
        try updateRootExtension(version.extensionName) { vrm in
            var meta = try vrm.requiredObject("meta", of: version.extensionName) ?? [:]
            body(&meta)
            vrm["meta"] = .object(meta)
        }
    }
}
