import Foundation

public struct GLTF: Codable {
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
    public let extensions: CodableAny?
    public let extras: CodableAny?
}

extension GLTF {
    public enum Version: UInt32 {
        case two = 2
    }
}

package extension GLTF {
    /// Rejects assets this parser does not implement.
    func validateSupportedAssetVersion() throws {
        guard asset.version.hasPrefix("2.") else {
            throw VRMError._notSupported("glTF asset version \(asset.version) is not supported")
        }
        if let minVersion = asset.minVersion, minVersion != "2.0" {
            throw VRMError._notSupported("glTF asset minVersion \(minVersion) is not supported")
        }
    }

    /// The root `extensions` object, typed as the per-extension dictionaries it
    /// holds, which is how every `VRMC_*` extension is read.
    func rootExtensions() throws -> [String: [String: Any]] {
        let raw = try extensions ??? .keyNotFound("extensions")
        return try raw.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")
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
