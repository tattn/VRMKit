#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#sampler

extension GLTF {
    public struct Sampler: Codable, Sendable {
        public let magFilter: MagFilter?
        public let minFilter: MinFilter?
        let _wrapS: Wrap?
        public var wrapS: Wrap {
            return self._wrapS ?? .REPEAT
        }
        let _wrapT: Wrap?
        public var wrapT: Wrap {
            return self._wrapT ?? .REPEAT
        }
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case magFilter
            case minFilter
            case _wrapS = "wrapS"
            case _wrapT = "wrapT"
            case name
            case extensions
            case extras
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            magFilter = try container.decodeIfPresent(Int.self, forKey: .magFilter).flatMap(MagFilter.init(lenientRawValue:))
            minFilter = try container.decodeIfPresent(Int.self, forKey: .minFilter).flatMap(MinFilter.init(rawValue:))
            _wrapS = try container.decodeIfPresent(Int.self, forKey: ._wrapS).flatMap(Wrap.init(rawValue:))
            _wrapT = try container.decodeIfPresent(Int.self, forKey: ._wrapT).flatMap(Wrap.init(rawValue:))
            name = try container.decodeIfPresent(String.self, forKey: .name)
            extensions = try container.decodeIfPresent(JSONValue.self, forKey: .extensions)
            extras = try container.decodeIfPresent(JSONValue.self, forKey: .extras)
        }

        public enum MagFilter: Int, Codable, Sendable {
            case NEAREST = 9728
            case LINEAR = 9729

            /// Files in the wild put a `minFilter` mipmap constant in `magFilter`, and UniVRM
            /// loads them, so such a value is read as the texel filter it names. A value that
            /// names no filter is read as absent, so the default applies as for any
            /// unknown enum value in a sampler.
            init?(lenientRawValue rawValue: Int) {
                switch MinFilter(rawValue: rawValue) {
                case .NEAREST, .NEAREST_MIPMAP_NEAREST, .NEAREST_MIPMAP_LINEAR:
                    self = .NEAREST
                case .LINEAR, .LINEAR_MIPMAP_NEAREST, .LINEAR_MIPMAP_LINEAR:
                    self = .LINEAR
                case nil:
                    return nil
                }
            }
        }

        public enum MinFilter: Int, Codable, Sendable {
            case NEAREST = 9728
            case LINEAR = 9729
            case NEAREST_MIPMAP_NEAREST = 9984
            case LINEAR_MIPMAP_NEAREST = 9985
            case NEAREST_MIPMAP_LINEAR = 9986
            case LINEAR_MIPMAP_LINEAR = 9987
        }

        public enum Wrap: Int, Codable, Sendable {
            case CLAMP_TO_EDGE = 33071
            case MIRRORED_REPEAT = 33648
            case REPEAT = 10497
        }
    }
}
