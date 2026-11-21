#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#animation

extension GLTF {
    public struct Animation: Decodable, Sendable {
        public let channels: [Channel]
        public let samplers: [Sampler]
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public struct Channel: Decodable, Sendable {
            package let sampler: Int
            package let target: Target
            package let extensions: JSONValue?
            let extras: JSONValue?

            public struct Target: Decodable, Sendable {
                package let node: Int?
                package let path: String
                package let extensions: JSONValue?
                let extras: JSONValue?

                /// The animated property, typed for the runtime. Nil for paths this
                /// library does not know, such as extension-defined ones.
                package var targetPath: TargetPath? {
                    TargetPath(rawValue: path)
                }

                package enum TargetPath: String {
                    case translation
                    case rotation
                    case scale
                    case weights
                }
            }
        }

        public struct Sampler: Decodable, Sendable {
            package let input: Int
            let _interpolation: Interpolation?
            package var interpolation: Interpolation { return _interpolation ?? .LINEAR }
            package let output: Int
            package let extensions: JSONValue?
            let extras: JSONValue?
            private enum CodingKeys: String, CodingKey {
                case input
                case _interpolation = "interpolation"
                case output
                case extensions
                case extras
            }

            public enum Interpolation: String, Decodable, Sendable {
                case LINEAR
                case STEP
                case CUBICSPLINE
            }
        }
    }
}
