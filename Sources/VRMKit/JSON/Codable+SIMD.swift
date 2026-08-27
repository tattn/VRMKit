import Foundation
import simd

/// Lenient vector decoding: VRM files in the wild write vectors short, long or
/// not at all, and a component the file does not state reads as the spec's
/// default rather than failing the load.
package extension KeyedDecodingContainer {
    func simd2(forKey key: Key, default defaultValue: Float) throws -> SIMD2<Float> {
        SIMD2<Float>(try decodeIfPresent([Double].self, forKey: key), default: defaultValue)
    }

    func simd3(forKey key: Key, default defaultValue: SIMD3<Float>) throws -> SIMD3<Float> {
        SIMD3<Float>(try decodeIfPresent([Double].self, forKey: key), default: defaultValue)
    }

    func simd4(forKey key: Key, default defaultValue: SIMD4<Float>) throws -> SIMD4<Float> {
        SIMD4<Float>(try decodeIfPresent([Double].self, forKey: key), default: defaultValue)
    }
}
