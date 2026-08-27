import Foundation

/// Why a document could not be read, edited or written.
///
/// The kind is what a caller branches on, the message is what it shows.
public struct VRMError: Error, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A part of glTF or VRM this package does not implement.
        case notSupported
        /// A GLB container of a version this package does not read.
        case notSupportedVersion(UInt32)
        /// A GLB chunk type this package does not read, ahead of the JSON one.
        case notSupportedChunkType(UInt32)
        /// A field the document is required to carry and does not.
        case keyNotFound(String)
        /// A document that contradicts itself or the spec, such as an index out
        /// of range or a length that overruns its buffer.
        case dataInconsistent
        /// A model naming no thumbnail, or one it does not carry.
        case thumbnailNotFound
    }

    public let kind: Kind

    /// What went wrong, in a sentence a person can read.
    public let message: String

    /// Where in VRMKit the error was raised, for a bug report. It names this
    /// package's own source, not the caller's, so it stays out of ``message``.
    public let origin: String?

    public init(kind: Kind, message: String, origin: String? = nil) {
        self.kind = kind
        self.message = message
        self.origin = origin
    }
}

public extension VRMError {
    static func notSupported(_ message: String) -> VRMError {
        VRMError(kind: .notSupported, message: message)
    }

    static func notSupportedVersion(_ version: UInt32) -> VRMError {
        VRMError(kind: .notSupportedVersion(version),
                 message: "glTF container version \(version) is not supported")
    }

    static func notSupportedChunkType(_ type: UInt32) -> VRMError {
        VRMError(kind: .notSupportedChunkType(type),
                 message: "GLB chunk type 0x\(String(type, radix: 16)) is not supported")
    }

    static func keyNotFound(_ key: String) -> VRMError {
        VRMError(kind: .keyNotFound(key), message: "the document carries no \"\(key)\"")
    }

    static func dataInconsistent(_ message: String) -> VRMError {
        VRMError(kind: .dataInconsistent, message: message)
    }

    static let thumbnailNotFound = VRMError(kind: .thumbnailNotFound,
                                            message: "the model names no thumbnail image")
}

extension VRMError: LocalizedError {
    public var errorDescription: String? { message }
}

extension VRMError: CustomStringConvertible {
    public var description: String { message }
}

extension VRMError: CustomDebugStringConvertible {
    public var debugDescription: String {
        guard let origin else { return message }
        return "\(message) [\(origin)]"
    }
}

package extension VRMError {
    /// The same, stamping where in VRMKit it was raised.
    static func _notSupported(_ message: @autoclosure () -> String,
                              file: StaticString = #fileID,
                              function: StaticString = #function,
                              line: UInt = #line) -> VRMError {
        VRMError(kind: .notSupported, message: message(), origin: _origin(file, function, line))
    }

    static func _dataInconsistent(_ message: @autoclosure () -> String,
                                  file: StaticString = #fileID,
                                  function: StaticString = #function,
                                  line: UInt = #line) -> VRMError {
        VRMError(kind: .dataInconsistent, message: message(), origin: _origin(file, function, line))
    }

    private static func _origin(_ file: StaticString, _ function: StaticString, _ line: UInt) -> String {
        "\(function)@\(file):\(line)"
    }
}
