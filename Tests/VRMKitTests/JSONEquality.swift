import Foundation
import Testing
import VRMKit

/// Compares two glTF JSON trees the way the format reads them: key order and
/// the spelling of a number are not part of the document, everything else is.
///
/// Returns the path of the first difference, or nil when the two are the same
/// document.
func jsonDifference(_ lhs: JSONValue, _ rhs: JSONValue, path: String = "") -> String? {
    if let lhs = lhs.objectValue, let rhs = rhs.objectValue {
        let keys = Set(lhs.keys).union(rhs.keys)
        for key in keys.sorted() {
            guard let left = lhs[key] else { return "\(path)/\(key): missing on the left" }
            guard let right = rhs[key] else { return "\(path)/\(key): missing on the right" }
            if let difference = jsonDifference(left, right, path: "\(path)/\(key)") { return difference }
        }
        return nil
    }
    if let lhs = lhs.arrayValue, let rhs = rhs.arrayValue {
        guard lhs.count == rhs.count else {
            return "\(path): \(lhs.count) elements on the left, \(rhs.count) on the right"
        }
        for index in lhs.indices {
            if let difference = jsonDifference(lhs[index], rhs[index], path: "\(path)[\(index)]") { return difference }
        }
        return nil
    }
    if lhs.isNull, rhs.isNull { return nil }
    if let left = lhs.doubleValue, let right = rhs.doubleValue {
        // A number survives a rewrite to within an ulp or two rather than exactly,
        // which is far below the precision of the floats glTF reads it back as.
        let tolerance = 1e-12 * Swift.max(abs(left), abs(right))
        guard abs(left - right) > tolerance else { return nil }
        return "\(path): \(left) vs \(right)"
    }
    if lhs == rhs { return nil }
    return "\(path): \(lhs) vs \(rhs)"
}

func jsonDifference(_ lhs: JSONObject, _ rhs: JSONObject, path: String = "") -> String? {
    jsonDifference(.object(lhs), .object(rhs), path: path)
}

func jsonDifference(_ lhs: [JSONObject], _ rhs: [JSONObject], path: String = "") -> String? {
    jsonDifference(.objects(lhs), .objects(rhs), path: path)
}

extension JSONObject {
    /// The same JSON object without the given keys, for comparing the parts of
    /// two documents that are meant to be identical.
    func removing(_ keys: String...) -> Self {
        var copy = self
        keys.forEach { copy.removeValue(forKey: $0) }
        return copy
    }
}

/// Compares what two documents' accessors actually read, rather than the
/// indices and offsets they read it through, which editing is free to move.
/// `offset` is where `lhs`'s accessors landed in `rhs`.
func expectSameAccessors(_ lhs: GLTFDocument,
                         _ rhs: GLTFDocument,
                         offset: Int = 0,
                         indices: [Int]? = nil,
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
    for index in indices ?? Array((lhs.gltf.accessors ?? []).indices) {
        let expected = try (try lhs.gltf.load(\.accessors, at: index))
            .packedData(bufferView: lhs.bufferViewProvider)
        let actual = try (try rhs.gltf.load(\.accessors, at: index + offset))
            .packedData(bufferView: rhs.bufferViewProvider)
        #expect(expected == actual, "accessor \(index)", sourceLocation: sourceLocation)
    }
}
