#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#asset-1

extension GLTF {
    public struct Asset: Codable, Sendable {
        public let copyright: String?
        public let generator: String?
        public let version: String
        public let minVersion: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?
    }
}
