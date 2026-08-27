import Foundation
import VRMKit
import VRMTestSupport

extension VRMSampleAsset {
    /// The fixture with `extensions.VRMC_vrm.specVersion` replaced. Passing nil
    /// removes the key entirely.
    func withVRMCSpecVersion(_ specVersion: JSONValue?) throws -> Data {
        try rewritingJSON { json in
            guard var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRMC_vrm") else {
                throw GLBRewriter.Error.invalidJSON
            }
            if let specVersion {
                vrm["specVersion"] = specVersion
            } else {
                vrm.removeValue(forKey: "specVersion")
            }
            extensions["VRMC_vrm"] = .object(vrm)
            json["extensions"] = .object(extensions)
        }
    }
}
