#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Reads JSON text (RFC 8259, any value at the top) into a ``JSONValue``.
///
/// Its own reader rather than `JSONSerialization`, which only full Foundation has and which
/// brings ICU with it off Apple platforms. A number written with a fraction or an exponent
/// reads as ``JSONValue/double(_:)`` and one without as ``JSONValue/int(_:)`` unless it
/// overflows `Int`, so a rewrite spells each number the way the document did.
struct JSONParser {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        let offset: Int

        var description: String { "\(message) at byte \(offset)" }
    }

    /// How deep arrays and objects may nest before the reader gives up instead of
    /// running out of stack.
    private static let maximumDepth = 512

    private let bytes: UnsafeBufferPointer<UInt8>
    private var offset = 0
    private var depth = 0

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var parser = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
            parser.skipByteOrderMark()
            parser.skipWhitespace()
            let value = try parser.readValue()
            parser.skipWhitespace()
            guard parser.offset == parser.bytes.count else { throw parser.failure("unexpected text after the value") }
            return value
        }
    }

    // MARK: - Values

    private mutating func readValue() throws -> JSONValue {
        guard let byte = peek() else { throw failure("unexpected end of the text") }
        switch byte {
        case UInt8(ascii: "{"): return try readObject()
        case UInt8(ascii: "["): return try readArray()
        case UInt8(ascii: "\""): return .string(try readString())
        case UInt8(ascii: "t"): try readLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try readLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try readLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try readNumber()
        default: throw failure("unexpected character")
        }
    }

    private mutating func readObject() throws -> JSONValue {
        try enter()
        offset += 1
        var members: [String: JSONValue] = [:]
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            offset += 1
            depth -= 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw failure("expected a member name") }
            let key = try readString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            members[key] = try readValue()
            skipWhitespace()
            if try readSeparator(closing: UInt8(ascii: "}")) { break }
        }
        depth -= 1
        return .object(members)
    }

    private mutating func readArray() throws -> JSONValue {
        try enter()
        offset += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            offset += 1
            depth -= 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try readValue())
            skipWhitespace()
            if try readSeparator(closing: UInt8(ascii: "]")) { break }
        }
        depth -= 1
        return .array(elements)
    }

    /// Reads the `,` before another member or element, or the closing bracket. True when it closed.
    private mutating func readSeparator(closing: UInt8) throws -> Bool {
        switch peek() {
        case UInt8(ascii: ","):
            offset += 1
            return false
        case closing:
            offset += 1
            return true
        default:
            throw failure("expected ',' or '\(Character(Unicode.Scalar(closing)))'")
        }
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw failure("arrays and objects nest too deep") }
    }

    private mutating func readLiteral(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        guard offset + count <= bytes.count,
              (0..<count).allSatisfy({ bytes[offset + $0] == literal.utf8Start[$0] })
        else { throw failure("unexpected character") }
        offset += count
    }

    private mutating func readNumber() throws -> JSONValue {
        let start = offset
        if peek() == UInt8(ascii: "-") { offset += 1 }
        if peek() == UInt8(ascii: "0") {
            offset += 1
        } else {
            guard skipDigits() > 0 else { throw failure("expected a digit") }
        }
        var isInteger = true
        if peek() == UInt8(ascii: ".") {
            offset += 1
            isInteger = false
            guard skipDigits() > 0 else { throw failure("expected a digit after '.'") }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            offset += 1
            isInteger = false
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { offset += 1 }
            guard skipDigits() > 0 else { throw failure("expected a digit in the exponent") }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<offset]), as: UTF8.self)
        if isInteger, let integer = Int(text) {
            return .int(integer)
        }
        guard let double = Double(text) else { throw failure("not a number") }
        return .double(double)
    }

    /// Skips decimal digits and returns how many there were.
    private mutating func skipDigits() -> Int {
        let start = offset
        while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            offset += 1
        }
        return offset - start
    }

    // MARK: - Strings

    private mutating func readString() throws -> String {
        offset += 1
        let start = offset
        // Most strings in a glTF carry no escapes and are decoded in place.
        while let byte = peek() {
            if byte == UInt8(ascii: "\"") {
                let string = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<offset]), as: UTF8.self)
                offset += 1
                return string
            }
            if byte == UInt8(ascii: "\\") { break }
            guard byte >= 0x20 else { throw failure("control character in a string") }
            offset += 1
        }
        var utf8 = Array(bytes[start..<offset])
        while let byte = peek() {
            offset += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                try readEscape(into: &utf8)
            case ..<0x20:
                throw failure("control character in a string")
            default:
                utf8.append(byte)
            }
        }
        throw failure("unterminated string")
    }

    private mutating func readEscape(into utf8: inout [UInt8]) throws {
        guard let byte = peek() else { throw failure("unterminated string") }
        offset += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(byte)
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            var scalar = UInt32(try readHexQuad())
            if (0xD800...0xDBFF).contains(scalar) {
                // A character outside the basic plane is written as a surrogate pair.
                guard peek() == UInt8(ascii: "\\"), offset + 1 < bytes.count, bytes[offset + 1] == UInt8(ascii: "u")
                else { throw failure("unpaired surrogate") }
                offset += 2
                let low = UInt32(try readHexQuad())
                guard (0xDC00...0xDFFF).contains(low) else { throw failure("unpaired surrogate") }
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(scalar) {
                throw failure("unpaired surrogate")
            }
            guard let unicode = Unicode.Scalar(scalar) else { throw failure("invalid escape") }
            utf8.append(contentsOf: UTF8.encode(unicode)!)
        default:
            throw failure("invalid escape")
        }
    }

    private mutating func readHexQuad() throws -> UInt16 {
        guard offset + 4 <= bytes.count else { throw failure("unterminated escape") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[offset]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw failure("invalid escape")
            }
            value = value << 4 | UInt16(digit)
            offset += 1
        }
        return value
    }

    // MARK: - Bytes

    private func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard peek() == byte else { throw failure("expected '\(Character(Unicode.Scalar(byte)))'") }
        offset += 1
    }

    private mutating func skipWhitespace() {
        while let byte = peek(),
              byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
                || byte == UInt8(ascii: "\t") {
            offset += 1
        }
    }

    private mutating func skipByteOrderMark() {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            offset = 3
        }
    }

    private func failure(_ message: String) -> Failure {
        Failure(message: message, offset: offset)
    }
}
