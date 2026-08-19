import Foundation

infix operator ???

package func ???<T>(lhs: T?,
                    error: @autoclosure () -> VRMError) throws -> T {
    guard let value = lhs else { throw error() }
    return value
}

