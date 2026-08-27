import Foundation

public struct GLTF: Codable, Sendable {
    public let extensionsUsed: [String]?
    public let extensionsRequired: [String]?
    public let accessors: [Accessor]?
    public let animations: [Animation]?
    public let asset: Asset
    public let buffers: [Buffer]?
    public let bufferViews: [BufferView]?
    public let cameras: [Camera]?
    public let images: [Image]?
    public let materials: [Material]?
    public let meshes: [Mesh]?
    public let nodes: [Node]?
    public let samplers: [Sampler]?
    /// The default scene, when the asset names one. glTF leaves it out for
    /// assets that are a library of nodes rather than something to render.
    public let scene: Int?
    public let scenes: [Scene]?
    public let skins: [Skin]?
    public let textures: [Texture]?
    public let extensions: JSONValue?
    public let extras: JSONValue?
}

extension GLTF {
    public enum Version: UInt32 {
        case two = 2
    }
}

public extension GLTF {
    /// The scene the asset draws, which every renderer resolves the same way.
    func defaultSceneIndex() throws -> Int {
        try GLTF.defaultSceneIndex(scene, among: scenes?.count ?? 0, of: "glTF")
    }
}

package extension GLTF {
    /// glTF leaves `scene` optional, so an asset of one scene has nothing to
    /// name, as UniVRM 0.x writes its models; one holding several and naming
    /// none says nothing about which to draw.
    ///
    /// Taken apart from ``GLTF`` so that the writing side, which works on raw
    /// JSON, resolves the default scene by the same rule.
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

    /// The root `extensions` object, which is how every `VRMC_*` extension is
    /// read. glTF lets an extension carry any JSON, so one whose value is not
    /// an object is left out rather than failing the load.
    func rootExtensions() throws -> [String: JSONObject] {
        let raw = try extensions ??? .keyNotFound("extensions")
        let members = try raw.objectValue ??? .dataInconsistent("the root extensions are not a JSON object")
        return members.compactMapValues(\.objectValue)
    }

    func load<T>(_ keyPath: KeyPath<GLTF, T?>) throws -> T {
        try self[keyPath: keyPath] ??? .keyNotFound(Self.description(of: keyPath))
    }

    /// One element of a glTF array, throwing instead of trapping when the index
    /// from the file is out of range.
    func load<T>(_ keyPath: KeyPath<GLTF, [T]?>, at index: Int) throws -> T {
        let values = try load(keyPath)
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
