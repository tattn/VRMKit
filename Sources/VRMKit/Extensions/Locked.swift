import Foundation

/// A value only one thread reads or writes at a time.
///
/// `Mutex` and `OSAllocatedUnfairLock` both say this better, and both ask for a
/// deployment target past the one this package supports.
package final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    package init(_ value: Value) {
        self.value = value
    }

    package func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
