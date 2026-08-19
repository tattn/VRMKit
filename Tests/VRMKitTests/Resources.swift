import Foundation
import VRMTestSupport

enum Resources {
    case aliciaSolid
    case seedSan

    var data: Data {
        switch self {
        case .aliciaSolid:
            let url = Bundle.module.url(forResource: "AliciaSolid", withExtension: "vrm")!
            return try! Data(contentsOf: url)
        case .seedSan:
            let url = Bundle.module.url(forResource: "Seed-san", withExtension: "vrm")!
            return try! Data(contentsOf: url)
        }
    }
}

extension Resources {
    /// The fixture with its glTF JSON rewritten, so tests can feed the loaders
    /// malformed or unusual files without shipping extra assets.
    func rewritingJSON(_ modify: (inout [String: Any]) throws -> Void) throws -> Data {
        try GLBRewriter.rewritingJSON(of: data, modify)
    }

    /// The fixture with `extensions.VRMC_vrm.specVersion` replaced. Passing nil
    /// removes the key entirely.
    func withVRMCSpecVersion(_ specVersion: Any?) throws -> Data {
        try rewritingJSON { json in
            guard var extensions = json["extensions"] as? [String: Any],
                  var vrm = extensions["VRMC_vrm"] as? [String: Any] else {
                throw GLBRewriter.Error.invalidJSON
            }
            if let specVersion {
                vrm["specVersion"] = specVersion
            } else {
                vrm.removeValue(forKey: "specVersion")
            }
            extensions["VRMC_vrm"] = vrm
            json["extensions"] = extensions
        }
    }
}
