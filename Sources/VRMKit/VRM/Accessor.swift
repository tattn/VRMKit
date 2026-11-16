#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#accessor

extension GLTF {
    public struct Accessor: Codable, Sendable {
        public let bufferView: Int?
        let _byteOffset: Int?
        public var byteOffset: Int { return _byteOffset ?? 0 }
        public let componentType: ComponentType
        let _normalized: Bool?
        public var normalized: Bool { return _normalized ?? false }
        public let count: Int
        public let type: Type
        public let max: [Float]?
        public let min: [Float]?
        public let sparse: Sparse?
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case bufferView
            case _byteOffset = "byteOffset"
            case componentType
            case _normalized = "normalized"
            case count
            case type
            case max
            case min
            case sparse
            case name
            case extensions
            case extras
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bufferView = try container.decodeIfPresent(Int.self, forKey: .bufferView)
            _byteOffset = try container.decodeIfPresent(Int.self, forKey: ._byteOffset)
            componentType = try container.decode(ComponentType.self, forKey: .componentType)
            _normalized = try container.decodeIfPresent(Bool.self, forKey: ._normalized)
            count = try container.decode(Int.self, forKey: .count)
            type = try container.decode(`Type`.self, forKey: .type)
            // The bounds are only hints, so ones written in the wrong shape (a bare number) read as absent.
            max = try? container.decodeIfPresent([Float].self, forKey: .max)
            min = try? container.decodeIfPresent([Float].self, forKey: .min)
            sparse = try container.decodeIfPresent(Sparse.self, forKey: .sparse)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            extensions = try container.decodeIfPresent(JSONValue.self, forKey: .extensions)
            extras = try container.decodeIfPresent(JSONValue.self, forKey: .extras)
        }
    }
}

extension GLTF.Accessor {
    public enum ComponentType: Int, Codable, Sendable {
        case byte = 5120
        case unsignedByte = 5121
        case short = 5122
        case unsignedShort = 5123
        case unsignedInt = 5125
        case float = 5126
    }

    public enum `Type`: String, Codable, Sendable {
        case SCALAR
        case VEC2
        case VEC3
        case VEC4
        case MAT2
        case MAT3
        case MAT4
    }

    public struct Sparse: Codable, Sendable {
        public let count: Int
        public let indices: Indices
        public let values: Values
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public struct Indices: Codable, Sendable {
            public let bufferView: Int
            let _byteOffset: Int?
            public var byteOffset: Int { return _byteOffset ?? 0 }
            public let componentType: ComponentType
            public let extensions: JSONValue?
            public let extras: JSONValue?
            private enum CodingKeys: String, CodingKey {
                case bufferView
                case _byteOffset = "byteOffset"
                case componentType
                case extensions
                case extras
            }
        }

        public struct Values: Codable, Sendable {
            public let bufferView: Int
            let _byteOffset: Int?
            public var byteOffset: Int { return _byteOffset ?? 0 }
            public let extensions: JSONValue?
            public let extras: JSONValue?
            private enum CodingKeys: String, CodingKey {
                case bufferView
                case _byteOffset = "byteOffset"
                case extensions
                case extras
            }
        }
    }
}
