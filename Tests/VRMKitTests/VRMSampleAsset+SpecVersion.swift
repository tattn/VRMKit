import Foundation
import VRMTestSupport

extension VRMSampleAsset {
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
