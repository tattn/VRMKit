import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#texture

extension GLTF {
    public struct Texture: Codable, Sendable {
        public let sampler: Int?
        /// Left out for a texture whose image an extension supplies, such as `KHR_texture_basisu`.
        public let source: Int?
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?
    }
}
