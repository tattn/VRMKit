import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#textureinfo

extension GLTF {
    public struct TextureInfo: Codable, Sendable {
        public let index: Int
        let _texCoord: Int?
        public var texCoord: Int { return _texCoord ?? 0 }
        public let extensions: JSONValue?
        public let extras: JSONValue?
        private enum CodingKeys: String, CodingKey {
            case index
            case _texCoord = "texCoord"
            case extensions
            case extras
        }
    }
}
