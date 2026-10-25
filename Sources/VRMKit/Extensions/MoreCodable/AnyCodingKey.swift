#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct AnyCodingKey : CodingKey {
    public var stringValue: String
    public var intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

}
