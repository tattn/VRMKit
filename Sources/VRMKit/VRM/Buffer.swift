import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#buffer

extension GLTF {
    public struct Buffer: Codable, Sendable {
        public let uri: String?
        public let byteLength: Int
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?
    }
}
