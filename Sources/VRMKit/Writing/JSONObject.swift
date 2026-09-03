import Foundation

/// One JSON object of a glTF document, held as the fields it carries so that
/// the ones VRMKit does not model survive a load / edit / save cycle.
package typealias JSONObject = [String: JSONValue]

// MARK: - Reading

package extension JSONObject {
    func object(_ key: String) -> JSONObject? { self[key]?.objectValue }
    func objects(_ key: String) -> [JSONObject] { self[key]?.arrayValue?.compactMap(\.objectValue) ?? [] }

    /// The object at `key`, nil where the document holds none. One that is not an
    /// object is refused rather than read as absent. `subject` names what holds the
    /// key, for the message.
    func requiredObject(_ key: String, of subject: String) throws -> JSONObject? {
        guard let value = self[key] else { return nil }
        return try value.objectValue ??? ._dataInconsistent("\(subject).\(key) is not a JSON object")
    }

    /// The objects of the array at `key`, nil where the document holds none. One
    /// that is not an array of objects is refused, since appending to it would
    /// throw away whatever it holds.
    func requiredObjects(_ key: String, of subject: String) throws -> [JSONObject]? {
        guard let value = self[key] else { return nil }
        guard let elements = value.arrayValue else {
            throw VRMError._dataInconsistent("\(subject).\(key) is not an array of JSON objects")
        }
        let objects = elements.compactMap(\.objectValue)
        guard objects.count == elements.count else {
            throw VRMError._dataInconsistent("\(subject).\(key) is not an array of JSON objects")
        }
        return objects
    }

    func string(_ key: String) -> String? { self[key]?.stringValue }
    func strings(_ key: String) -> [String] { self[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    func ints(_ key: String) -> [Int]? { self[key]?.arrayValue?.compactMap(\.intValue) }
    func count(_ key: String) -> Int { self[key]?.arrayValue?.count ?? 0 }

    /// A whole number that is not an array index: ``index(_:)`` bounds its
    /// result the way glTF bounds an index, and a byte offset outgrows that.
    func int(_ key: String) -> Int? { self[key]?.intValue }

    func float(_ key: String) -> Float? { self[key]?.floatValue }

    func index(_ key: String) -> Int? { self[key]?.indexValue }

    /// The keys of the `textureInfo`s directly under this object, which glTF and
    /// the material extensions it defines all spell ending in `Texture`.
    var textureSlotKeys: [String] { keys.filter { $0.hasSuffix("Texture") } }

    /// Nil unless every element is a number.
    func floats(_ key: String) -> [Float]? {
        guard let values = self[key]?.arrayValue else { return nil }
        let floats = values.compactMap(\.floatValue)
        return floats.count == values.count ? floats : nil
    }

    func simd2Value(forKey key: String, default defaultValue: SIMD2<Float>) -> SIMD2<Float> {
        guard let values = self[key]?.arrayValue else { return defaultValue }
        return SIMD2<Float>(values.float(at: 0, default: defaultValue.x),
                            values.float(at: 1, default: defaultValue.y))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONValue.object(self).decode(type)
    }

    /// Decodes the member at `key`, which the document is required to carry.
    func decodeJSON<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
        try (self[key] ??? .keyNotFound(key)).decode(type)
    }

    /// Decodes an optional member: a missing key yields nil, while a present
    /// but malformed value still throws.
    func decodeJSONIfPresent<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        try self[key]?.decode(type)
    }
}

package extension Array where Element == JSONValue {
    func float(at index: Int, default defaultValue: Float) -> Float {
        guard indices.contains(index) else { return defaultValue }
        return self[index].floatValue ?? defaultValue
    }
}

// MARK: - Writing

package extension JSONObject {
    /// Assigns `value`, or removes the key when it is nil.
    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value {
            self[key] = value
        } else {
            removeValue(forKey: key)
        }
    }

    mutating func set(_ key: String, _ value: JSONObject?) {
        set(key, value.map(JSONValue.object))
    }

    mutating func set(_ key: String, _ value: [JSONObject]?) {
        set(key, value.map(JSONValue.objects))
    }

    mutating func set(_ key: String, _ value: Int?) {
        set(key, value.map(JSONValue.int))
    }

    mutating func set(_ key: String, _ value: String?) {
        set(key, value.map(JSONValue.string))
    }

    mutating func set(_ key: String, _ value: Float?) {
        set(key, value.map(JSONValue.number))
    }

    mutating func set(_ key: String, _ value: [Float]?) {
        set(key, value.map(JSONValue.numbers))
    }

    /// Leaves the key out at the 0 glTF defaults it to.
    mutating func setNonZero(_ key: String, _ value: Int) {
        set(key, value == 0 ? nil : .int(value))
    }

    /// Replaces every element of the array at `key`, adding no array to a
    /// document that has none.
    mutating func mapObjects(_ key: String, _ transform: (JSONObject) throws -> JSONObject) rethrows {
        guard self[key] != nil else { return }
        self[key] = .objects(try objects(key).map(transform))
    }

    mutating func appendObjects(_ elements: [JSONObject], to key: String) {
        guard !elements.isEmpty else { return }
        self[key] = .objects(objects(key) + elements)
    }

    /// Appends one object and returns the index it was given.
    @discardableResult
    mutating func appendObject(_ element: JSONObject, to key: String) -> Int {
        var existing = objects(key)
        existing.append(element)
        self[key] = .objects(existing)
        return existing.count - 1
    }

    /// Points a buffer view, or the meshopt slice shaped like one, at the one
    /// buffer a GLB has, `offsets` saying where each source buffer landed in it. A
    /// view already on it keeps the offset it had, and one naming a buffer the
    /// document does not hold is refused.
    mutating func rebaseOntoSingleBuffer(offsets: [Int]) throws {
        let buffer = self["buffer"] == nil
            ? 0
            : try index("buffer") ??? ._dataInconsistent("a buffer view names a buffer that is not an index")
        guard let offset = offsets[safe: buffer] else {
            throw VRMError._dataInconsistent(
                "a buffer view names buffer \(buffer), and the document holds \(offsets.count)"
            )
        }
        let byteOffset = int("byteOffset") ?? 0
        let rebased = byteOffset.addingReportingOverflow(offset)
        guard byteOffset >= 0, !rebased.overflow else {
            throw VRMError._dataInconsistent(
                "a buffer view's byte offset \(byteOffset) is not one the single buffer can hold"
            )
        }
        self["buffer"] = 0
        guard offset != 0 else { return }
        self["byteOffset"] = .int(rebased.partialValue)
    }

    mutating func appendIndex(_ index: Int, to key: String) {
        self[key] = .numbers((ints(key) ?? []) + [index])
    }

    mutating func removeIndex(_ index: Int, from key: String, dropWhenEmpty: Bool) {
        guard let values = ints(key), values.contains(index) else { return }
        let remaining = values.filter { $0 != index }
        set(key, remaining.isEmpty && dropWhenEmpty ? nil : .numbers(remaining))
    }

    /// Updates one object of the array at `key`, leaving the elements around it
    /// as they were. An array holding no object at `index` is left alone.
    mutating func updateObject(at index: Int,
                               in key: String,
                               _ body: (inout JSONObject) throws -> Void) rethrows {
        guard var elements = self[key]?.arrayValue,
              var object = elements[safe: index]?.objectValue else { return }
        try body(&object)
        elements[index] = .object(object)
        self[key] = .array(elements)
    }

    mutating func withObject(_ key: String, _ body: (inout JSONObject) throws -> Void) rethrows {
        guard var value = object(key) else { return }
        try body(&value)
        self[key] = .object(value)
    }
}
