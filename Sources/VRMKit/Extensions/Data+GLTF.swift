#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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
            self = try Data(mappingFileAt: URL(gltfUri: gltfUrlString, relativeTo: rootDirectory))
        }
    }

    /// A file's bytes mapped rather than copied: only the pages a read touches come in, as
    /// clean memory the system can drop again, however long a document keeps them.
    ///
    /// While the bytes live the file must be replaced, never rewritten in place: the bytes
    /// would change under a reader, and a page a truncation removed crashes the one reaching it.
    init(mappingFileAt url: URL) throws {
#if os(Android)
        // FoundationEssentials there reads the file into memory for `.mappedIfSafe`.
        try self.init(contentsOf: url, options: .alwaysMapped)
#else
        try self.init(contentsOf: url, options: .mappedIfSafe)
#endif
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

    /// The media type the bytes name themselves, for the two image formats a
    /// glTF may carry, or nil for anything else. A GLB embeds an image without
    /// the file name that would say what it is, so the signature is all there is.
    var imageMediaType: String? {
        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        return nil
    }

    /// Checks that `count` elements of `size` bytes each, `stride` bytes apart from `offset`
    /// on, lie inside the receiver. Offsets count from the receiver's start, which for a
    /// buffer view is not the buffer's.
    func validateElements(offset: Int, size: Int, stride: Int, count: Int) throws {
        guard offset >= 0, size > 0, count >= 0, stride >= size else {
            throw VRMError._dataInconsistent(
                "invalid accessor layout (offset: \(offset), size: \(size), stride: \(stride), count: \(count))"
            )
        }
        guard count > 0 else { return }
        let packed = size.multipliedReportingOverflow(by: count)
        guard let requiredBytes = Int.accessorExtent(offset: offset, stride: stride, count: count, size: size),
              !packed.overflow else {
            throw VRMError._dataInconsistent(
                "accessor extent overflows (offset: \(offset), size: \(size), stride: \(stride), count: \(count))"
            )
        }
        guard requiredBytes <= self.count else {
            throw VRMError._dataInconsistent(
                "accessor needs \(requiredBytes) bytes but its buffer view holds \(self.count)"
            )
        }
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
    /// percent-encoded, so `My%20Buffer.bin` names a file with a space in it. Only
    /// local files are read.
    init(gltfUri: String, relativeTo rootDirectory: URL?) throws {
        // A uri that is not a valid URI reference is taken as a literal path,
        // which is what exporters writing unencoded characters mean by it.
        let uri = URL(string: gltfUri, relativeTo: rootDirectory)
        guard let uri, uri.scheme != nil else {
            // A relative uri names a file beside the glTF, so without that
            // directory there is no base to resolve it against.
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
