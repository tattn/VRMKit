import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#animation

extension GLTF {
    public struct Animation: Codable {
        public let channels: [Channel]
        public let samplers: [Sampler]
        public let name: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?

        public struct Channel: Codable {
            package let sampler: Int
            package let target: Target
            package let extensions: CodableAny?
            package let extras: CodableAny?

            public struct Target: Codable {
                package let node: Int?
                package let path: String
                package let extensions: CodableAny?
                package let extras: CodableAny?

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

        public struct Sampler: Codable {
            package let input: Int
            let _interpolation: Interpolation?
            package var interpolation: Interpolation { return _interpolation ?? .LINEAR }
            package let output: Int
            package let extensions: CodableAny?
            package let extras: CodableAny?
            private enum CodingKeys: String, CodingKey {
                case input
                case _interpolation = "interpolation"
                case output
                case extensions
                case extras
            }

            public enum Interpolation: String, Codable {
                case LINEAR
                case STEP
                case CUBICSPLINE
            }
        }
    }
}
