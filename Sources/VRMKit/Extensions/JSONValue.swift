import Foundation

/// The untyped JSON a glTF document is read into: what `JSONSerialization`
/// produces for the extension objects VRMKit models by hand, and what an edit
/// builds in the same shape.
///
/// Decoding one goes back through the serialization a save goes through, so a
/// value an edit wrote and a value a load parsed decode the same way, and the
/// `Codable` types below describe the JSON rather than a second representation
/// of it.
package enum JSONValue {
    package static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return try JSONDecoder().decode(type, from: data)
    }
}

package extension Dictionary where Key == String {
    /// Decodes the member at `key`, which the document is required to carry.
    func decodeJSON<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
        try JSONValue.decode(type, from: try self[key] ??? .keyNotFound(key))
    }

    /// Decodes an optional member: a missing key yields nil, while a present
    /// but malformed value still throws.
    func decodeJSONIfPresent<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let value = self[key] else { return nil }
        return try JSONValue.decode(type, from: value)
    }
}
