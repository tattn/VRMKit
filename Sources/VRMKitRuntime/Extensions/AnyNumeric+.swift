import Foundation
import VRMKit

/// A loosely-typed JSON number, as they appear in VRM extension dictionaries.
/// Swift's `Float` / `Double` / `Int` all bridge to `NSNumber`, so one cast
/// covers every numeric shape JSONSerialization produces; booleans bridge to
/// `NSNumber` too but are not numbers here.
private func jsonNumber(_ value: Any) -> NSNumber? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number
}

/// Coerces a loosely-typed JSON number into a `Float`. Values a `Float` cannot
/// represent (`1e100` overflows to infinity) are rejected so callers fall back
/// to their defaults instead of feeding infinities or NaNs into the renderer.
package func numericFloatValue(_ value: Any) -> Float? {
    guard let float = jsonNumber(value)?.floatValue, float.isFinite else { return nil }
    return float
}

/// Coerces a loosely-typed JSON number into an `Int` index. Only exact,
/// non-negative integers within `Int32` are accepted: glTF indices are small,
/// and `Int(_:)` traps on values a fixed-width integer cannot represent. The
/// number is read as a `Double` because `Float` rounds integers past 2^24, so
/// `16_777_217` and `Int32.max` would both pass a `Float` test as some other
/// value.
package func numericIndexValue(_ value: Any) -> Int? {
    guard let number = jsonNumber(value),
          let index = Int(exactly: number.doubleValue),
          index >= 0, index <= Int(Int32.max) else { return nil }
    return index
}

package extension Array where Element == Any {
    func float(at index: Int, default defaultValue: Float) -> Float {
        guard indices.contains(index) else { return defaultValue }
        return numericFloatValue(self[index]) ?? defaultValue
    }
}

package extension Dictionary where Key == String, Value == Any {
    func float(_ key: String) -> Float? {
        self[key].flatMap(numericFloatValue)
    }

    func index(_ key: String) -> Int? {
        self[key].flatMap(numericIndexValue)
    }

    func simd2Value(forKey key: String, default defaultValue: SIMD2<Float>) -> SIMD2<Float> {
        guard let values = self[key] as? [Any] else { return defaultValue }
        return SIMD2<Float>(values.float(at: 0, default: defaultValue.x),
                            values.float(at: 1, default: defaultValue.y))
    }

    func simd3(_ key: String) -> SIMD3<Float>? {
        (self[key] as? [Any]).map {
            SIMD3<Float>($0.float(at: 0, default: 0),
                         $0.float(at: 1, default: 0),
                         $0.float(at: 2, default: 0))
        }
    }

    func simd4(_ key: String) -> SIMD4<Float>? {
        (self[key] as? [Any]).map {
            SIMD4<Float>($0.float(at: 0, default: 1),
                         $0.float(at: 1, default: 1),
                         $0.float(at: 2, default: 1),
                         $0.float(at: 3, default: 1))
        }
    }
}

package extension CodableAny {
    /// The value as a JSON object, or an empty dictionary when it is not one.
    var dictionaryValue: [String: Any] {
        value as? [String: Any] ?? [:]
    }
}
