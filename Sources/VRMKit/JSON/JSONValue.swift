import Foundation

/// One JSON value of a glTF document.
///
/// The shape extensions and `extras` this package does not model travel in, so
/// that a load and an edit hand them through untouched.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// Kept apart from ``double(_:)`` so a rewrite spells a number the way the document did.
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

public extension JSONValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The members of an object, empty for a value that is not one.
    var dictionaryValue: [String: JSONValue] { objectValue ?? [:] }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// Nil for a number that is not exactly an integer.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    /// Nil for a number a `Float` cannot represent: `1e100` overflowing to infinity
    /// is worse for a renderer than falling back to a default.
    var floatValue: Float? {
        guard let double = doubleValue else { return nil }
        let float = Float(double)
        return float.isFinite ? float : nil
    }

    /// A whole number, not negative, and inside the `Int32` a glTF index fits in.
    var indexValue: Int? {
        guard let index = intValue, index >= 0, index <= Int(Int32.max) else { return nil }
        return index
    }
}

// MARK: - Writing

public extension JSONValue {
    /// The shape every glTF top-level list takes.
    static func objects(_ values: [[String: JSONValue]]) -> JSONValue {
        .array(values.map(JSONValue.object))
    }

    static func number(_ value: Float) -> JSONValue {
        .double(Double(value))
    }

    static func numbers(_ values: some Sequence<Float>) -> JSONValue {
        .array(values.map { .double(Double($0)) })
    }

    static func numbers(_ values: some Sequence<Int>) -> JSONValue {
        .array(values.map(JSONValue.int))
    }

    static func strings(_ values: some Sequence<String>) -> JSONValue {
        .array(values.map(JSONValue.string))
    }

    static func simd(_ value: SIMD3<Float>) -> JSONValue {
        .numbers([value.x, value.y, value.z])
    }

    static func simd(_ value: SIMD4<Float>) -> JSONValue {
        .numbers([value.x, value.y, value.z, value.w])
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Equality

public extension JSONValue {
    /// JSON has one number type, so `1` and `1.0` are equal however this package spells them.
    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(lhs), .bool(rhs)): return lhs == rhs
        case let (.int(lhs), .int(rhs)): return lhs == rhs
        case let (.double(lhs), .double(rhs)): return lhs == rhs
        // `Double(exactly:)`: past 2^53 the conversion rounds, and two integers a
        // `Double` cannot tell apart are still two different numbers.
        case let (.int(lhs), .double(rhs)), let (.double(rhs), .int(lhs)): return Double(exactly: lhs) == rhs
        case let (.string(lhs), .string(rhs)): return lhs == rhs
        case let (.array(lhs), .array(rhs)): return lhs == rhs
        case let (.object(lhs), .object(rhs)): return lhs == rhs
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        // Both number cases hash as the one number they stand for, matching `==`.
        case .int(let value):
            hasher.combine(2)
            hasher.combine(value)
        case .double(let value):
            hasher.combine(2)
            if let integer = Int(exactly: value) {
                hasher.combine(integer)
            } else {
                hasher.combine(value)
            }
        case .string(let value):
            hasher.combine(3)
            hasher.combine(value)
        case .array(let value):
            hasher.combine(4)
            hasher.combine(value)
        case .object(let value):
            hasher.combine(5)
            hasher.combine(value)
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        // Before `Double`, so a number written without a fraction is written back without one.
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Bridging typed values

public extension JSONValue {
    /// The JSON an `Encodable` value writes itself as.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONValueEncoding.encode(value)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONValueDecoding.decode(type, from: self)
    }

    /// Keys sorted, so writing the same document twice gives the same bytes.
    func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    init(parsing data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw VRMError._dataInconsistent("not valid JSON: \(error.localizedDescription)")
        }
        self.init(foundation: object)
    }

    /// Wraps what `JSONSerialization` parsed, keeping how each number was spelled.
    private init(foundation object: Any) {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if UnicodeScalar(UInt8(number.objCType.pointee)) == "d" {
                self = .double(number.doubleValue)
            } else if let int = Int(exactly: number) {
                self = .int(int)
            } else {
                self = .double(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let elements as [Any]:
            self = .array(elements.map(JSONValue.init(foundation:)))
        case let members as [String: Any]:
            self = .object(members.mapValues(JSONValue.init(foundation:)))
        default:
            self = .null
        }
    }
}
