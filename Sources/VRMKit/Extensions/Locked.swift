#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A value only one thread reads or writes at a time.
///
/// `Mutex` and `OSAllocatedUnfairLock` both say this better, and both ask for a
/// deployment target past the one this package supports. A pthread mutex rather than
/// `NSLock`, which only full Foundation has (it brings ICU with it off Apple platforms).
package final class Locked<Value>: @unchecked Sendable {
    // On the heap, because a pthread mutex must not move once initialized.
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private var value: Value

    package init(_ value: Value) {
        self.value = value
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    package func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body(&value)
    }
}
