import Foundation

/// A glTF asset's typed model.
///
/// glTF spells an empty top-level array by leaving it out, so each reads as empty
/// when absent and is written only when it holds something.
public struct GLTF: Codable, Sendable {
    public let extensionsUsed: [String]
    public let extensionsRequired: [String]
    public let accessors: [Accessor]
    public let animations: [Animation]
    public let asset: Asset
    public let buffers: [Buffer]
    public let bufferViews: [BufferView]
    public let cameras: [Camera]
    public let images: [Image]
    public let materials: [Material]
    public let meshes: [Mesh]
    public let nodes: [Node]
    public let samplers: [Sampler]
    /// The default scene, when the asset names one. glTF leaves it out for assets
    /// that are a library of nodes rather than something to render.
    public let scene: Int?
    public let scenes: [Scene]
    public let skins: [Skin]
    public let textures: [Texture]
    public let extensions: JSONValue?
    public let extras: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case extensionsUsed, extensionsRequired, accessors, animations, asset
        case buffers, bufferViews, cameras, images, materials, meshes, nodes
        case samplers, scene, scenes, skins, textures, extensions, extras
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extensionsUsed = try container.decodeIfPresent([String].self, forKey: .extensionsUsed) ?? []
        extensionsRequired = try container.decodeIfPresent([String].self, forKey: .extensionsRequired) ?? []
        accessors = try container.decodeIfPresent([Accessor].self, forKey: .accessors) ?? []
        animations = try container.decodeIfPresent([Animation].self, forKey: .animations) ?? []
        asset = try container.decode(Asset.self, forKey: .asset)
        buffers = try container.decodeIfPresent([Buffer].self, forKey: .buffers) ?? []
        bufferViews = try container.decodeIfPresent([BufferView].self, forKey: .bufferViews) ?? []
        cameras = try container.decodeIfPresent([Camera].self, forKey: .cameras) ?? []
        images = try container.decodeIfPresent([Image].self, forKey: .images) ?? []
        materials = try container.decodeIfPresent([Material].self, forKey: .materials) ?? []
        meshes = try container.decodeIfPresent([Mesh].self, forKey: .meshes) ?? []
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        samplers = try container.decodeIfPresent([Sampler].self, forKey: .samplers) ?? []
        scene = try container.decodeIfPresent(Int.self, forKey: .scene)
        scenes = try container.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
        skins = try container.decodeIfPresent([Skin].self, forKey: .skins) ?? []
        textures = try container.decodeIfPresent([Texture].self, forKey: .textures) ?? []
        extensions = try container.decodeIfPresent(JSONValue.self, forKey: .extensions)
        extras = try container.decodeIfPresent(JSONValue.self, forKey: .extras)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(extensionsUsed, forKey: .extensionsUsed)
        try container.encodeIfNotEmpty(extensionsRequired, forKey: .extensionsRequired)
        try container.encodeIfNotEmpty(accessors, forKey: .accessors)
        try container.encodeIfNotEmpty(animations, forKey: .animations)
        try container.encode(asset, forKey: .asset)
        try container.encodeIfNotEmpty(buffers, forKey: .buffers)
        try container.encodeIfNotEmpty(bufferViews, forKey: .bufferViews)
        try container.encodeIfNotEmpty(cameras, forKey: .cameras)
        try container.encodeIfNotEmpty(images, forKey: .images)
        try container.encodeIfNotEmpty(materials, forKey: .materials)
        try container.encodeIfNotEmpty(meshes, forKey: .meshes)
        try container.encodeIfNotEmpty(nodes, forKey: .nodes)
        try container.encodeIfNotEmpty(samplers, forKey: .samplers)
        try container.encodeIfPresent(scene, forKey: .scene)
        try container.encodeIfNotEmpty(scenes, forKey: .scenes)
        try container.encodeIfNotEmpty(skins, forKey: .skins)
        try container.encodeIfNotEmpty(textures, forKey: .textures)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try container.encodeIfPresent(extras, forKey: .extras)
    }
}

private extension KeyedEncodingContainer {
    /// glTF forbids an empty top-level array, so one writes as no array at all.
    mutating func encodeIfNotEmpty<T: Encodable>(_ values: [T], forKey key: Key) throws {
        guard !values.isEmpty else { return }
        try encode(values, forKey: key)
    }
}

extension GLTF {
    public enum Version: UInt32 {
        case two = 2
    }
}

public extension GLTF {
    /// The scene the asset draws, which every renderer resolves the same way.
    func defaultSceneIndex() throws -> Int {
        try GLTF.defaultSceneIndex(scene, among: scenes.count, of: "glTF")
    }
}

package extension GLTF {
    /// glTF leaves `scene` optional, as UniVRM 0.x writes its models, so an asset of one
    /// scene has nothing to name and one holding several says nothing about which to draw.
    ///
    /// Kept apart from ``GLTF`` so the writing side, which works on raw JSON, resolves the
    /// default scene by the same rule.
    static func defaultSceneIndex(_ scene: Int?, among count: Int, of subject: String) throws -> Int {
        guard let index = scene else {
            guard count == 1 else {
                throw VRMError._dataInconsistent(
                    "the \(subject) names no default scene among the \(count) it holds"
                )
            }
            return 0
        }
        guard index >= 0, index < count else {
            throw VRMError._dataInconsistent(
                "the \(subject)'s default scene \(index) is out of range for its \(count) scenes"
            )
        }
        return index
    }

    /// Rejects assets this parser does not implement.
    func validateSupportedAssetVersion() throws {
        guard asset.version.hasPrefix("2.") else {
            throw VRMError._notSupported("glTF asset version \(asset.version) is not supported")
        }
        if let minVersion = asset.minVersion, minVersion != "2.0" {
            throw VRMError._notSupported("glTF asset minVersion \(minVersion) is not supported")
        }
    }

    /// The root `extensions` object, which is how every `VRMC_*` extension is read.
    /// One whose value is not an object is left out rather than failing the load.
    func rootExtensions() throws -> [String: JSONObject] {
        let raw = try extensions ??? .keyNotFound("extensions")
        let members = try raw.objectValue ??? .dataInconsistent("the root extensions are not a JSON object")
        return members.compactMapValues(\.objectValue)
    }

    /// The image a texture reads. An extension may supply it in place of the core `source`,
    /// and this package decodes none of those.
    func imageIndex(ofTextureAt index: Int) throws -> Int {
        try load(\.textures, at: index).source
            ??? ._notSupported(
                "texture \(index) takes its image from an extension this renderer does not implement"
            )
    }

    /// One element of a glTF array, throwing instead of trapping on an index out of range.
    func load<T>(_ keyPath: KeyPath<GLTF, [T]>, at index: Int) throws -> T {
        let values = self[keyPath: keyPath]
        guard values.indices.contains(index) else {
            throw VRMError._dataInconsistent(
                "index \(index) is out of range for the \(values.count) elements of \(Self.description(of: keyPath))"
            )
        }
        return values[index]
    }

    private static func description<T>(of keyPath: KeyPath<GLTF, T>) -> String {
        if #available(macOS 13.3, iOS 16.4, watchOS 9.4, *) {
            return keyPath.debugDescription
        } else {
            return "\(keyPath)"
        }
    }
}
