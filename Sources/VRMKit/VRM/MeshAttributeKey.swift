import Foundation

extension GLTF.Mesh.Primitive {
    /// The name a primitive stores one of its vertex attributes under.
    ///
    /// glTF names attributes rather than numbering them, and an asset may carry
    /// names beyond the ones drawn here. Keeping the name lets those reach a
    /// renderer that knows them and survive a rewrite that does not, where a closed
    /// enum would drop them at decode time.
    public struct AttributeKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let POSITION = AttributeKey(rawValue: "POSITION")
        public static let NORMAL = AttributeKey(rawValue: "NORMAL")
        public static let TANGENT = AttributeKey(rawValue: "TANGENT")
        public static let TEXCOORD_0 = AttributeKey(rawValue: "TEXCOORD_0")
        public static let TEXCOORD_1 = AttributeKey(rawValue: "TEXCOORD_1")
        public static let COLOR_0 = AttributeKey(rawValue: "COLOR_0")
        public static let JOINTS_0 = AttributeKey(rawValue: "JOINTS_0")
        public static let WEIGHTS_0 = AttributeKey(rawValue: "WEIGHTS_0")

        /// The `n`-th UV set, `TEXCOORD_0` being the first.
        public static func texcoord(_ set: Int) -> AttributeKey {
            AttributeKey(rawValue: "TEXCOORD_\(set)")
        }

        /// The `n`-th set of joint indices, four influences to a set.
        public static func joints(_ set: Int) -> AttributeKey {
            AttributeKey(rawValue: "JOINTS_\(set)")
        }

        /// The `n`-th set of joint weights, four influences to a set.
        public static func weights(_ set: Int) -> AttributeKey {
            AttributeKey(rawValue: "WEIGHTS_\(set)")
        }

        /// The `n`-th vertex color set.
        public static func color(_ set: Int) -> AttributeKey {
            AttributeKey(rawValue: "COLOR_\(set)")
        }
    }
}

extension GLTF.Mesh.Primitive.AttributeKey: Codable {
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension GLTF.Mesh.Primitive.AttributeKey: CodingKeyRepresentable {
    /// Without this a `[AttributeKey: Int]` encodes as an array of alternating
    /// keys and values rather than as the JSON object glTF asks for.
    public var codingKey: any CodingKey {
        Key(stringValue: rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}

extension GLTF.Mesh.Primitive.AttributeKey: CustomStringConvertible {
    public var description: String { rawValue }
}
