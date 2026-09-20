import Foundation

/// The captured differential reference JSON files under `Tests/Assets/ReferenceOutputs`.
///
/// Each file validates against `Tests/Assets/ReferenceOutputs/schema.json` and records the
/// source implementation, its pinned revision, and the fixture it was captured from. See
/// `scripts/capture-reference-output/README.md` for the capture procedure.
public enum ReferenceOutputAsset: String, CaseIterable, Sendable {
    case univrmAvatarSampleM = "univrm/AvatarSample_M.json"

    public var data: Data {
        TestAssetBundle.data(forFixture: "ReferenceOutputs/\(rawValue)")
    }
}
