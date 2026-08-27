import Foundation

/// Decodes `Decodable` values straight off a ``JSONValue`` tree.
///
/// Bridging a subtree into the typed model this way walks the values as they
/// stand; nothing is serialized back to text on the way.
package enum JSONValueDecoding {
    package static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try DecoderImpl(value: value, path: nil).unwrap(type)
    }
}

/// One step of a coding path, linked upwards. A path is walked on every nested
/// value but read only by an error message, so it is kept as one link per
/// container rather than copied into an array per element.
private final class PathNode {
    let parent: PathNode?
    let key: any CodingKey

    init(parent: PathNode?, key: any CodingKey) {
        self.parent = parent
        self.key = key
    }

    static func materialize(_ node: PathNode?) -> [any CodingKey] {
        var keys: [any CodingKey] = []
        var current = node
        while let node = current {
            keys.append(node.key)
            current = node.parent
        }
        return keys.reversed()
    }
}

private struct DecoderImpl: Decoder {
    let value: JSONValue
    let path: PathNode?

    var codingPath: [any CodingKey] { PathNode.materialize(path) }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func unwrap<T: Decodable>(_ type: T.Type) throws -> T {
        // A `JSONValue` target takes the subtree as it stands.
        if T.self == JSONValue.self, let value = value as? T { return value }
        // `JSONDecoder` reads `Data` from base64 by default; matched here so a
        // model gaining a `Data` field never changes wire format by accident.
        if T.self == Data.self {
            guard let string = value.stringValue, let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
                                                        debugDescription: "expected base64-encoded data"))
            }
            return data as! T
        }
        return try T(from: self)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let members) = value else {
            throw DecodingError.typeMismatch([String: JSONValue].self, .init(
                codingPath: codingPath,
                debugDescription: "expected a JSON object, found \(value.typeName)"))
        }
        return KeyedDecodingContainer(KeyedContainer(members: members, path: path))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw DecodingError.typeMismatch([JSONValue].self, .init(
                codingPath: codingPath,
                debugDescription: "expected a JSON array, found \(value.typeName)"))
        }
        return UnkeyedContainer(elements: elements, path: path)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleContainer(value: value, path: path)
    }
}

// MARK: - Reading one scalar

private extension JSONValue {
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "a boolean"
        case .int, .double: return "a number"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    func mismatch<T>(_ type: T.Type, at path: PathNode?) -> DecodingError {
        .typeMismatch(type, .init(codingPath: PathNode.materialize(path),
                                  debugDescription: "expected \(type), found \(typeName)"))
    }

    func integer<T: FixedWidthInteger>(_ type: T.Type, at path: @autoclosure () -> PathNode?) throws -> T {
        let converted: T?
        switch self {
        case .int(let value): converted = T(exactly: value)
        // JSON has one number type, so `1.0` still reads as the integer it is.
        case .double(let value): converted = T(exactly: value)
        default: converted = nil
        }
        guard let converted else { throw mismatch(type, at: path()) }
        return converted
    }
}

// MARK: - Containers

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let members: [String: JSONValue]
    let path: PathNode?

    var codingPath: [any CodingKey] { PathNode.materialize(path) }
    var allKeys: [Key] { members.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { members[key.stringValue] != nil }

    private func value(forKey key: Key) throws -> JSONValue {
        guard let value = members[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath,
                debugDescription: "no value for key \"\(key.stringValue)\""))
        }
        return value
    }

    private func node(_ key: Key) -> PathNode { PathNode(parent: path, key: key) }

    func decodeNil(forKey key: Key) throws -> Bool { try value(forKey: key).isNull }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let value = try value(forKey: key)
        guard let result = value.boolValue else { throw value.mismatch(type, at: node(key)) }
        return result
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let value = try value(forKey: key)
        guard let result = value.stringValue else { throw value.mismatch(type, at: node(key)) }
        return result
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let value = try value(forKey: key)
        guard let result = value.doubleValue else { throw value.mismatch(type, at: node(key)) }
        return result
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let value = try value(forKey: key)
        guard let result = value.floatValue else { throw value.mismatch(type, at: node(key)) }
        return result
    }

    func decode<T: FixedWidthInteger & Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try value(forKey: key).integer(type, at: node(key))
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try DecoderImpl(value: try value(forKey: key), path: node(key)).unwrap(type)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type,
                                               forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try DecoderImpl(value: try value(forKey: key), path: node(key)).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try DecoderImpl(value: try value(forKey: key), path: node(key)).unkeyedContainer()
    }

    /// `superEncoder()` writes under `"super"`, so this reads the same key back.
    func superDecoder() throws -> any Decoder {
        let key = SuperKey()
        guard let value = members[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath,
                debugDescription: "no value for key \"\(key.stringValue)\""))
        }
        return DecoderImpl(value: value, path: PathNode(parent: path, key: key))
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        DecoderImpl(value: try value(forKey: key), path: node(key))
    }
}

private struct UnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [JSONValue]
    let path: PathNode?
    var currentIndex = 0

    var codingPath: [any CodingKey] { PathNode.materialize(path) }
    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    private mutating func next<T>(_ type: T.Type) throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(type, .init(
                codingPath: codingPath,
                debugDescription: "no more elements past index \(currentIndex)"))
        }
        defer { currentIndex += 1 }
        return elements[currentIndex]
    }

    private func node(at index: Int) -> PathNode {
        PathNode(parent: path, key: IndexKey(intValue: index))
    }

    mutating func decodeNil() throws -> Bool {
        // Codable has a nil that fails leave the element unconsumed.
        let value = try next(JSONValue.self)
        guard value.isNull else {
            currentIndex -= 1
            return false
        }
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let index = currentIndex
        let value = try next(type)
        guard let result = value.boolValue else { throw value.mismatch(type, at: node(at: index)) }
        return result
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let index = currentIndex
        let value = try next(type)
        guard let result = value.stringValue else { throw value.mismatch(type, at: node(at: index)) }
        return result
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let index = currentIndex
        let value = try next(type)
        guard let result = value.doubleValue else { throw value.mismatch(type, at: node(at: index)) }
        return result
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        let index = currentIndex
        let value = try next(type)
        guard let result = value.floatValue else { throw value.mismatch(type, at: node(at: index)) }
        return result
    }

    mutating func decode<T: FixedWidthInteger & Decodable>(_ type: T.Type) throws -> T {
        let index = currentIndex
        let value = try next(type)
        return try value.integer(type, at: node(at: index))
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let index = currentIndex
        let value = try next(type)
        return try DecoderImpl(value: value, path: node(at: index)).unwrap(type)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let index = currentIndex
        let value = try next([String: JSONValue].self)
        return try DecoderImpl(value: value, path: node(at: index)).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let index = currentIndex
        let value = try next([JSONValue].self)
        return try DecoderImpl(value: value, path: node(at: index)).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let index = currentIndex
        let value = try next(JSONValue.self)
        return DecoderImpl(value: value, path: node(at: index))
    }
}

private struct SingleContainer: SingleValueDecodingContainer {
    let value: JSONValue
    let path: PathNode?

    var codingPath: [any CodingKey] { PathNode.materialize(path) }

    func decodeNil() -> Bool { value.isNull }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard let result = value.boolValue else { throw value.mismatch(type, at: path) }
        return result
    }

    func decode(_ type: String.Type) throws -> String {
        guard let result = value.stringValue else { throw value.mismatch(type, at: path) }
        return result
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard let result = value.doubleValue else { throw value.mismatch(type, at: path) }
        return result
    }

    func decode(_ type: Float.Type) throws -> Float {
        guard let result = value.floatValue else { throw value.mismatch(type, at: path) }
        return result
    }

    func decode<T: FixedWidthInteger & Decodable>(_ type: T.Type) throws -> T {
        try value.integer(type, at: path)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try DecoderImpl(value: value, path: path).unwrap(type)
    }
}

/// The key Codable stores a superclass's values under.
struct SuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }

    init() {}
    init?(stringValue: String) { guard stringValue == "super" else { return nil } }
    init?(intValue: Int) { return nil }
}

/// An array position on a coding path.
struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? 0)" }

    init(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { return nil }
}
