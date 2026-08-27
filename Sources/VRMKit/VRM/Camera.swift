import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#camera

extension GLTF {
    public struct Camera: Codable, Sendable {
        public let orthographic: Orthographic?
        public let perspective: Perspective?
        public let type: Type
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public struct Orthographic: Codable, Sendable {
            public let xmag: Float
            public let ymag: Float
            public let zfar: Float
            public let znear: Float
            public let extensions: JSONValue?
            public let extras: JSONValue?
        }

        public struct Perspective: Codable, Sendable {
            public let aspectRatio: Float?
            public let yfov: Float
            public let zfar: Float?
            public let znear: Float
            public let extensions: JSONValue?
            public let extras: JSONValue?
        }

        public enum `Type`: String, Codable, Sendable {
            case perspective
            case orthographic
        }
    }
}
