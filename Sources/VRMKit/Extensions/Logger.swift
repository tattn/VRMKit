#if !canImport(OSLog)
#if canImport(Android)
import Android
#else
import Foundation
#endif

/// `os.Logger`'s shape where there is no OSLog, so that a call site reads the same on
/// every platform. Android writes to logcat; elsewhere the message goes to standard error.
struct Logger: Sendable {
    let subsystem: String
    let category: String

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    func warning(_ message: LogMessage) {
#if canImport(Android)
        _ = __android_log_write(Int32(ANDROID_LOG_WARN.rawValue), "\(subsystem).\(category)", message.text)
#else
        FileHandle.standardError.write(Data("[\(subsystem).\(category)] \(message.text)\n".utf8))
#endif
    }
}

/// Withholds a value unless it is marked public, as OSLog does once the app is not being debugged.
enum LogPrivacy: Sendable {
    case `public`
    case `private`
}

struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: some Any, privacy: LogPrivacy = .private) {
            text += privacy == .public ? "\(value)" : "<private>"
        }
    }

    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }
}
#endif
