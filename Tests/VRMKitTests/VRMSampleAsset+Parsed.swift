import VRMKit
import VRMTestSupport

extension VRMSampleAsset {
    /// The fixture read as a model, parsed once per test process: a whole model costs more
    /// to parse than most of the tests that only look something up in it.
    var parsedVRM: VRM {
        get throws {
            switch self {
            case .aliciaSolid: try ParsedVRMSampleAsset.aliciaSolid.get()
            case .seedSan: try ParsedVRMSampleAsset.seedSan.get()
            case .vrm1ConstraintTwist: try ParsedVRMSampleAsset.vrm1ConstraintTwist.get()
            }
        }
    }
}

private enum ParsedVRMSampleAsset {
    static let aliciaSolid = Result { try VRM(data: VRMSampleAsset.aliciaSolid.data) }
    static let seedSan = Result { try VRM(data: VRMSampleAsset.seedSan.data) }
    static let vrm1ConstraintTwist = Result { try VRM(data: VRMSampleAsset.vrm1ConstraintTwist.data) }
}
