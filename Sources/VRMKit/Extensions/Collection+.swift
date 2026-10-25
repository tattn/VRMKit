#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension Collection {
    package subscript(safe index: Index) -> Element? {
        return startIndex <= index && index < endIndex ? self[index] : nil
    }
}
