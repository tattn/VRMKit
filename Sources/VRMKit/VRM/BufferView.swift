import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#bufferview

extension GLTF {
    public struct BufferView: Codable, Sendable {
        public let buffer: Int
        let _byteOffset: Int?
        public var byteOffset: Int { return _byteOffset ?? 0 }
        public let byteLength: Int
        public let byteStride: Int?
        public let target: Int?
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?
        private enum CodingKeys: String, CodingKey {
            case buffer
            case _byteOffset = "byteOffset"
            case byteLength
            case byteStride
            case target
            case name
            case extensions
            case extras
        }
    }
}
