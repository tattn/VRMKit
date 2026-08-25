import Foundation

/// Writing the resources a picture is made of. A mesh's base color and a VRM's
/// thumbnail are the same three entries, so they are written the same way.
extension GLTFEditableDocument {
    /// The texture reading `image` through `sampler`.
    func appendTexture(_ image: Data,
                       mediaType: String,
                       sampler: GLTFTextureSampler = GLTFTextureSampler()) -> Int {
        var texture: JSONObject = ["source": appendImage(image, mediaType: mediaType)]
        texture.set("sampler", appendSampler(sampler))
        return json.appendObject(texture, to: .textures)
    }

    /// Writes an image into the BIN buffer, the only place a GLB has to keep
    /// one, and returns the index of the `images` entry naming it.
    func appendImage(_ image: Data, mediaType: String) -> Int {
        let view = json.appendObject(["buffer": 0,
                                      "byteOffset": appendToBinary(image),
                                      "byteLength": image.count],
                                     to: .bufferViews)
        return json.appendObject(["bufferView": view, "mimeType": mediaType], to: .images)
    }

    /// Nothing is written when the sampler asks for what glTF already reads a
    /// texture naming none as, and a field at its default is left out for the
    /// same reason.
    private func appendSampler(_ sampler: GLTFTextureSampler) -> Int? {
        guard sampler != GLTFTextureSampler() else { return nil }

        var object = JSONObject()
        if sampler.wrapS != .REPEAT { object["wrapS"] = sampler.wrapS.rawValue }
        if sampler.wrapT != .REPEAT { object["wrapT"] = sampler.wrapT.rawValue }
        object.set("magFilter", sampler.magFilter?.rawValue)
        object.set("minFilter", sampler.minFilter?.rawValue)

        return json.appendObject(object, to: .samplers)
    }
}
