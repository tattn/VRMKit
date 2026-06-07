import Foundation

enum Resources {
    case aliciaSolid
    case seedSan

    var data: Data {
        return try! Data(contentsOf: url)
    }

    var url: URL {
        switch self {
        case .aliciaSolid:
            return Bundle.module.url(forResource: "AliciaSolid", withExtension: "vrm")!
        case .seedSan:
            return Bundle.module.url(forResource: "Seed-san", withExtension: "vrm")!
        }
    }
}
