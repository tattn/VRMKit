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
    let _scene: Int?
    public var scene: Int { return _scene ?? 0 }
    public let scenes: [Scene]?
    public let skins: [Skin]?
    public let textures: [Texture]?
    public let extensions: CodableAny?
    public let extras: CodableAny?
    private enum CodingKeys: String, CodingKey {
        case extensionsUsed
        case extensionsRequired
        case accessors
        case animations
        case asset
        case buffers
        case bufferViews
        case cameras
        case images
        case materials
        case meshes
        case nodes
        case samplers
        case _scene = "scene"
        case scenes
        case skins
        case textures
        case extensions
        case extras
    }
}

extension GLTF {
    public enum Version: UInt32 {
        case two = 2
    }
}

package extension GLTF {
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
