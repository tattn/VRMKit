import Foundation

/// One JSON object of a glTF document, held as `JSONSerialization` produces it
/// so that fields VRMKit does not model survive a load / edit / save cycle.
package typealias JSONObject = [String: Any]

package extension JSONObject {
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func objects(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }
    func string(_ key: String) -> String? { self[key] as? String }
    func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }
    func ints(_ key: String) -> [Int]? { self[key] as? [Int] }
    func count(_ key: String) -> Int { (self[key] as? [Any])?.count ?? 0 }

    /// A whole number that is not an array index: ``index(_:)`` bounds its
    /// result the way glTF bounds an index, and a byte offset outgrows that.
    func int(_ key: String) -> Int? {
        self[key].flatMap(jsonNumber).flatMap { Int(exactly: $0.doubleValue) }
    }

    /// The keys of the `textureInfo`s directly under this object, which glTF
    /// and the material extensions it defines all spell ending in `Texture`. A
    /// key shaped like one under `extras` is the document's own field, so
    /// nothing walks in there.
    var textureSlotKeys: [String] { keys.filter { $0.hasSuffix("Texture") } }

    /// Nil unless every element is a number an edit or a load can have written.
    func floats(_ key: String) -> [Float]? {
        guard let values = self[key] as? [Any] else { return nil }
        let floats = values.compactMap(numericFloatValue)
        return floats.count == values.count ? floats : nil
    }

    /// Decodes through the serialization a save goes through, so numbers an
    /// edit wrote as Swift values decode like the ones a load parsed.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONValue.decode(type, from: self)
    }

    /// Assigns `value`, or removes the key when it is nil.
    mutating func set(_ key: String, _ value: Any?) {
        if let value {
            self[key] = value
        } else {
            removeValue(forKey: key)
        }
    }

    /// Leaves the key out at the 0 glTF defaults it to.
    mutating func setNonZero(_ key: String, _ value: Int) {
        set(key, value == 0 ? nil : value)
    }

    /// Replaces every element of the array at `key`, adding no array to a
    /// document that has none.
    mutating func mapObjects(_ key: String, _ transform: (JSONObject) throws -> JSONObject) rethrows {
        guard self[key] != nil else { return }
        self[key] = try objects(key).map(transform)
    }

    mutating func appendObjects(_ elements: [JSONObject], to key: String) {
        guard !elements.isEmpty else { return }
        var existing = objects(key)
        existing.append(contentsOf: elements)
        self[key] = existing
    }

    /// Appends one object and returns the index it was given.
    @discardableResult
    mutating func appendObject(_ element: JSONObject, to array: GLTFArray) -> Int {
        var existing = objects(array)
        existing.append(element)
        self[array] = existing
        return existing.count - 1
    }

    /// Points a buffer view, or the meshopt slice shaped like one, at the one
    /// buffer a GLB has, `offsets` saying where each source buffer landed in it.
    /// A view already on it keeps the offset it had, so that loading and saving
    /// a single-buffer document changes nothing.
    ///
    /// A view naming a buffer the document does not hold is refused rather than
    /// pointed at the first one, which would be loadable but wrong.
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
        self["byteOffset"] = rebased.partialValue
    }

    mutating func removeIndex(_ index: Int, from key: String, dropWhenEmpty: Bool) {
        guard let values = ints(key), values.contains(index) else { return }
        let remaining = values.filter { $0 != index }
        set(key, remaining.isEmpty && dropWhenEmpty ? nil : remaining)
    }

    mutating func withObject(_ key: String, _ body: (inout JSONObject) throws -> Void) rethrows {
        guard var value = object(key) else { return }
        try body(&value)
        self[key] = value
    }
}
