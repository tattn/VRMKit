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

        guard buffer.byteLength >= 0, count >= buffer.byteLength else {
            throw VRMError._dataInconsistent(
                "buffer byteLength \(buffer.byteLength) is invalid for a \(count) byte resource"
            )
        }
    }

    init(gltfUrlString: String, relativeTo rootDirectory: URL?) throws {
        if let data = try Data(dataURI: gltfUrlString) {
            self = data
        } else {
            self = try Data(contentsOf: URL(gltfUri: gltfUrlString, relativeTo: rootDirectory))
        }
    }

    /// The bytes an RFC 2397 `data:` URI carries, or nil when the string is not
    /// one. `;base64` is optional there: without it the data is percent-encoded.
    init?(dataURI: String) throws {
        guard dataURI.hasPrefix("data:") else { return nil }
        let body = dataURI.dropFirst("data:".count)
        guard let separator = body.firstIndex(of: ",") else {
            throw VRMError._dataInconsistent("the data uri has no \",\" separating its media type from its data")
        }
        let payload = body[body.index(after: separator)...]
        guard body[..<separator].hasSuffix(";base64") else {
            self = try Data(percentEncoded: payload)
                ??? .dataInconsistent("failed to decode the percent-encoded data uri")
            return
        }
        self = try Data(base64Encoded: String(payload)) ??? .dataInconsistent("failed to load base64 data")
    }

    /// Percent-decodes a URI component into the octets it stands for, which
    /// unlike `removingPercentEncoding` survives data that is not text.
    private init?(percentEncoded string: Substring) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count)
        var iterator = string.utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next()?.hexDigitValue,
                  let low = iterator.next()?.hexDigitValue else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        self.init(bytes)
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
    ///
    /// `offset` is relative to the receiver, which a buffer view is a slice of,
    /// and the result is a `Data` of its own so that packed accessor bytes never
    /// carry the buffer they were read out of.
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
            if startIndex == 0, offset == 0, dataSize == self.count { return self }
            let start = startIndex + offset
            return subdata(in: start..<start + dataSize)
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

private extension UInt8 {
    /// The value of one ASCII hexadecimal digit, or nil for anything else.
    var hexDigitValue: UInt8? {
        switch self {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return self - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return self - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return self - UInt8(ascii: "A") + 10
        default: return nil
        }
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

package extension URL {
    /// Resolves a glTF `uri` against the asset's directory.
    ///
    /// A `uri` is a URI reference, not a file path: its reserved characters are
    /// percent-encoded, so `My%20Buffer.bin` names a file with a space in it.
    /// Only local files are read: a glTF must not fetch resources off the
    /// network on the caller's behalf.
    init(gltfUri: String, relativeTo rootDirectory: URL?) throws {
        // A uri that is not a valid URI reference is taken as a literal path,
        // which is what exporters writing unencoded characters mean by it.
        let uri = URL(string: gltfUri, relativeTo: rootDirectory)
        guard let uri, uri.scheme != nil else {
            // A relative uri names a file beside the glTF, so without that
            // directory the only base left is the working directory of the
            // process, which holds some unrelated file of the same name.
            guard let rootDirectory else {
                throw VRMError._dataInconsistent(
                    """
                    the glTF uri \"\(gltfUri)\" is relative to the directory of the asset, which this document was loaded without; \
                    load it from a URL, or pass the directory its resources live in as rootDirectory
                    """
                )
            }
            self = URL(fileURLWithPath: uri?.relativePath ?? gltfUri, relativeTo: rootDirectory)
            return
        }
        guard uri.isFileURL else {
            throw VRMError._notSupported("the \(uri.scheme ?? "") scheme of the glTF uri \"\(gltfUri)\" is not loadable")
        }
        self = uri
    }
}
