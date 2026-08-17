import Foundation

/// A bounds-checked, little-endian cursor over a `Data`.
///
/// Every read is validated against the end of the data, so a truncated header or
/// an overrunning chunk length throws a ``VRMError`` instead of trapping.
struct BinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    /// The number of bytes consumed so far.
    var bytesRead: Int { offset - data.startIndex }

    mutating func readUInt32() throws -> UInt32 {
        // GLB is little-endian regardless of the host, so the value is
        // assembled from the bytes instead of loaded.
        let bytes = try readData(count: MemoryLayout<UInt32>.size)
        return bytes.reduce(UInt32(0)) { $0 >> 8 | UInt32($1) << 24 }
    }

    mutating func readData(count: Int) throws -> Data {
        let end = offset.addingReportingOverflow(count)
        guard count >= 0, !end.overflow, end.partialValue <= data.endIndex else {
            throw VRMError._dataInconsistent(
                "reading \(count) bytes at offset \(bytesRead) overruns the \(data.count) byte file"
            )
        }
        defer { offset = end.partialValue }
        return data.subdata(in: offset..<end.partialValue)
    }
}
