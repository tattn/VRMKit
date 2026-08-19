import Foundation

/// The `.vrm` fixtures that ship with the test bundle.
public enum VRMSampleAsset: String, CaseIterable, Sendable {
    /// A VRM 0.x model. The 0.x loading paths need one, as the others are 1.0.
    case aliciaSolid = "AliciaSolid.vrm"
    /// A VRM 1.0 model with MToon materials, expressions and spring bones.
    case seedSan = "Seed-san.vrm"
    /// A VRM 1.0 model exercising `VRMC_node_constraint`.
    case vrm1ConstraintTwist = "VRM1_Constraint_Twist_Sample.vrm"

    public var url: URL {
        TestAssetBundle.url(forFixture: "VRM/\(rawValue)")
    }

    public var data: Data {
        TestAssetBundle.data(forFixture: "VRM/\(rawValue)")
    }

    /// The fixture with its glTF JSON rewritten, so tests can feed the loaders
    /// malformed or unusual files without shipping extra assets.
    public func rewritingJSON(_ modify: (inout [String: Any]) throws -> Void) throws -> Data {
        try GLBRewriter.rewritingJSON(of: data, modify)
    }
}
