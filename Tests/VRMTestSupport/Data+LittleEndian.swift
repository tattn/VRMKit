import Foundation

public extension Data {
    /// Little-endian float / uint16 payloads for the hand-written glTF fixtures.
    init(littleEndianFloats values: [Float]) {
        self.init()
        for value in values {
            Swift.withUnsafeBytes(of: value.bitPattern.littleEndian) { append(contentsOf: $0) }
        }
    }

    mutating func appendLittleEndian(_ values: [UInt16]) {
        for value in values {
            Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
        }
    }

    /// Labelled, so the untyped array literals of the UInt16 callers stay
    /// unambiguous.
    mutating func appendLittleEndian(unsignedInts values: [UInt32]) {
        for value in values {
            Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
        }
    }
}
