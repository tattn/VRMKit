import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#image

extension GLTF {
    public struct Image: Codable, Sendable {
        public let uri: String?
        public let mimeType: String?
        public let bufferView: Int?
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?
    }
}
