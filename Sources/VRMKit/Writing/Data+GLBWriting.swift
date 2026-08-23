import Foundation

package extension Data {
    /// The bytes missing before the boundary every chunk and view starts on.
    var fourByteBoundaryPadding: Int { (4 - count % 4) % 4 }

    /// The JSON chunk pads with spaces and the BIN chunk with zeros, so the
    /// padding stays valid content of the chunk.
    mutating func padToFourByteBoundary(with byte: UInt8 = 0) {
        append(contentsOf: repeatElement(byte, count: fourByteBoundaryPadding))
    }

    /// Appends on that boundary and returns the offset it landed at.
    @discardableResult
    mutating func appendAligned(_ data: Data) -> Int {
        padToFourByteBoundary()
        let offset = count
        append(data)
        return offset
    }

    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
