import Foundation

package extension Data {
    init(buffer: GLTF.Buffer, relativeTo rootDirectory: URL?, binaryBuffer: Data?) throws {
        if let uri = buffer.uri {
            self = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let data = binaryBuffer {
            self = data
        } else {
            throw VRMError._dataInconsistent("failed to load buffers")
        }

        guard count >= buffer.byteLength else {
            throw VRMError._dataInconsistent("out of length \(count) >= \(buffer.byteLength)")
        }
    }

    init(gltfUrlString: String, relativeTo rootDirectory: URL?) throws {
        if let base64Str = gltfUrlString.retrievedBase64EncodedString() {
            self = try Data(base64Encoded: base64Str) ??? .dataInconsistent("failed to load base64 data")
        } else {
            let url = URL(fileURLWithPath: gltfUrlString, relativeTo: rootDirectory)
            self = try Data(contentsOf: url)
        }
    }

    /// All-zero data for a glTF accessor with no bufferView.
    init(zeroedElementCount count: Int, elementSize: Int) throws {
        guard count >= 0, elementSize > 0 else {
            throw VRMError._dataInconsistent("invalid accessor size (count: \(count), size: \(elementSize))")
        }
        let byteCount = elementSize.multipliedReportingOverflow(by: count)
        guard !byteCount.overflow else {
            throw VRMError._dataInconsistent("accessor size overflows (count: \(count), size: \(elementSize))")
        }
        self.init(count: byteCount.partialValue)
    }

    /// Copies `count` elements of `size` bytes each, `stride` bytes apart,
    /// starting at `offset`, throwing when the described range overruns the
    /// receiver.
    func subdata(offset: Int, size: Int, stride: Int, count: Int) throws -> Data {
        guard offset >= 0, size > 0, count >= 0, stride >= size else {
            throw VRMError._dataInconsistent(
                "invalid accessor layout (offset: \(offset), size: \(size), stride: \(stride), count: \(count))"
            )
        }
        guard count > 0 else { return Data() }
        let packed = size.multipliedReportingOverflow(by: count)
        guard let requiredBytes = Int.accessorExtent(offset: offset, stride: stride, count: count, size: size),
              !packed.overflow else {
            throw VRMError._dataInconsistent(
                "accessor extent overflows (offset: \(offset), size: \(size), stride: \(stride), count: \(count))"
            )
        }
        let dataSize = packed.partialValue
        guard requiredBytes <= self.count else {
            throw VRMError._dataInconsistent(
                "accessor needs \(requiredBytes) bytes but its buffer view holds \(self.count)"
            )
        }

        if stride == size {
            if offset == 0, dataSize == self.count { return self }
            return subdata(in: offset..<offset + dataSize)
        }

        var indexData = Data(count: dataSize)

        indexData.withUnsafeMutableBytes { rawDst in
            guard let dst = rawDst.bindMemory(to: UInt8.self).baseAddress else { return }
            withUnsafeBytes { rawSrc in
                guard let src = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return }
                for pos in 0..<count {
                    let srcPos = stride * pos + offset
                    let dstPos = size * pos
                    memcpy(dst.advanced(by: dstPos), src.advanced(by: srcPos), size)
                }
            }
        }
        return indexData
    }
}

private extension String {
    func retrievedBase64EncodedString() -> String? {
        guard starts(with: "data:") else { return nil }
        return components(separatedBy: ";base64,").last
    }
}

package extension Int {
    /// `offset + stride * (count - 1) + size`, or nil when that overflows.
    static func accessorExtent(offset: Int, stride: Int, count: Int, size: Int) -> Int? {
        let span = stride.multipliedReportingOverflow(by: count - 1)
        guard !span.overflow else { return nil }
        let start = offset.addingReportingOverflow(span.partialValue)
        guard !start.overflow else { return nil }
        let end = start.partialValue.addingReportingOverflow(size)
        guard !end.overflow else { return nil }
        return end.partialValue
    }
}
