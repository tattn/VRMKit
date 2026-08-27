import Foundation

/// Encodes `Encodable` values straight into a ``JSONValue`` tree.
///
/// The counterpart of ``JSONValueDecoding``: a typed value becomes the JSON it
/// would be written as, without a trip through serialized text.
package enum JSONValueEncoding {
    package static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let future = Future()
        try EncoderImpl(future: future, codingPath: []).box(value)
        return future.resolved
    }
}

/// Where an encoded value lands.
///
/// Codable hands out containers that are written to after they are returned, so
/// what a container fills has to be shared by reference and read at the end.
private final class Future {
    enum Kind {
        case empty
        case value(JSONValue)
        case object(ObjectBox)
        case array(ArrayBox)
    }
    var kind: Kind = .empty

    var resolved: JSONValue {
        switch kind {
        case .empty: return .null
        case .value(let value): return value
        case .object(let box): return .object(box.members.mapValues(\.resolved))
        case .array(let box): return .array(box.elements.map(\.resolved))
        }
    }

    /// The object this future holds, made on first use so keyed containers
    /// requested twice write into the same one.
    func object() -> ObjectBox {
        if case .object(let box) = kind { return box }
        let box = ObjectBox()
        kind = .object(box)
        return box
    }

    func array() -> ArrayBox {
        if case .array(let box) = kind { return box }
        let box = ArrayBox()
        kind = .array(box)
        return box
    }
}

private final class ObjectBox {
    var members: [String: Future] = [:]

    func future(forKey key: String) -> Future {
        if let existing = members[key] { return existing }
        let future = Future()
        members[key] = future
        return future
    }
}

private final class ArrayBox {
    var elements: [Future] = []

    func append() -> Future {
        let future = Future()
        elements.append(future)
        return future
    }
}

/// ``JSONValue`` spells a whole number as an `Int`, so one that does not fit is
/// refused rather than trapped on.
private func jsonInt<T: FixedWidthInteger>(_ value: T, at codingPath: [any CodingKey]) throws -> JSONValue {
    guard let int = Int(exactly: value) else {
        throw EncodingError.invalidValue(value, EncodingError.Context(
            codingPath: codingPath,
            debugDescription: "\(value) is outside the range JSON writes whole numbers in"))
    }
    return .int(int)
}

private struct EncoderImpl: Encoder {
    let future: Future
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func box<T: Encodable>(_ value: T) throws {
        // A `JSONValue` writes as the tree it already is.
        if let value = value as? JSONValue {
            future.kind = .value(value)
            return
        }
        // `JSONEncoder` writes `Data` as base64 by default; matched here so a
        // model gaining a `Data` field never changes wire format by accident.
        if let value = value as? Data {
            future.kind = .value(.string(value.base64EncodedString()))
            return
        }
        try value.encode(to: self)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedContainer(box: future.object(), codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        UnkeyedContainer(box: future.array(), codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleContainer(future: future, codingPath: codingPath)
    }
}

// MARK: - Containers

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: ObjectBox
    let codingPath: [any CodingKey]

    private func path(_ key: Key) -> [any CodingKey] { codingPath + [key] }

    private func store(_ value: JSONValue, forKey key: Key) {
        box.future(forKey: key.stringValue).kind = .value(value)
    }

    mutating func encodeNil(forKey key: Key) throws { store(.null, forKey: key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { store(.bool(value), forKey: key) }
    mutating func encode(_ value: String, forKey key: Key) throws { store(.string(value), forKey: key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { store(.double(value), forKey: key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { store(.double(Double(value)), forKey: key) }

    mutating func encode<T: FixedWidthInteger & Encodable>(_ value: T, forKey key: Key) throws {
        store(try jsonInt(value, at: path(key)), forKey: key)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try EncoderImpl(future: box.future(forKey: key.stringValue), codingPath: path(key)).box(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        EncoderImpl(future: box.future(forKey: key.stringValue), codingPath: path(key))
            .container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        EncoderImpl(future: box.future(forKey: key.stringValue), codingPath: path(key)).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let key = SuperKey()
        return EncoderImpl(future: box.future(forKey: key.stringValue), codingPath: codingPath + [key])
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        EncoderImpl(future: box.future(forKey: key.stringValue), codingPath: path(key))
    }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let box: ArrayBox
    let codingPath: [any CodingKey]

    var count: Int { box.elements.count }

    private func store(_ value: JSONValue) {
        box.append().kind = .value(value)
    }

    private func nextPath() -> [any CodingKey] { codingPath + [IndexKey(intValue: count)] }

    /// The encoder for the next element, whose path is read before appending moves the index on.
    private func nextEncoder() -> EncoderImpl {
        let codingPath = nextPath()
        return EncoderImpl(future: box.append(), codingPath: codingPath)
    }

    mutating func encodeNil() throws { store(.null) }
    mutating func encode(_ value: Bool) throws { store(.bool(value)) }
    mutating func encode(_ value: String) throws { store(.string(value)) }
    mutating func encode(_ value: Double) throws { store(.double(value)) }
    mutating func encode(_ value: Float) throws { store(.double(Double(value))) }

    mutating func encode<T: FixedWidthInteger & Encodable>(_ value: T) throws {
        store(try jsonInt(value, at: nextPath()))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try nextEncoder().box(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        nextEncoder().container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        nextEncoder().unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        nextEncoder()
    }
}

private struct SingleContainer: SingleValueEncodingContainer {
    let future: Future
    let codingPath: [any CodingKey]

    private func store(_ value: JSONValue) {
        future.kind = .value(value)
    }

    mutating func encodeNil() throws { store(.null) }
    mutating func encode(_ value: Bool) throws { store(.bool(value)) }
    mutating func encode(_ value: String) throws { store(.string(value)) }
    mutating func encode(_ value: Double) throws { store(.double(value)) }
    mutating func encode(_ value: Float) throws { store(.double(Double(value))) }

    mutating func encode<T: FixedWidthInteger & Encodable>(_ value: T) throws {
        store(try jsonInt(value, at: codingPath))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try EncoderImpl(future: future, codingPath: codingPath).box(value)
    }
}
