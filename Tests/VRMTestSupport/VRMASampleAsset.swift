import Foundation

/// The `.vrma` fixtures that ship with the test bundle.
public enum VRMASampleAsset: String, Sendable {
    /// A CC0 walk cycle: a real full-body motion, 54 humanoid bones and a hips
    /// translation, authored on a skeleton unlike either bundled `.vrm`.
    case walk = "walk.vrma"
    /// The MIT-licensed sample from pixiv/three-vrm. See
    /// `Tests/Assets/VRMA/README.md` for its channels and provenance.
    case test = "test.vrma"

    public var url: URL {
        TestAssetBundle.url(forFixture: "VRMA/\(rawValue)")
    }
}
