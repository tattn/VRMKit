import VRMKit
import SceneKit

typealias InverseBindMatrix = NSValue

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension Array where Element == InverseBindMatrix {
    init(accessor: PackedAccessor) throws {
        self = try accessor.float4x4Elements().map {
            InverseBindMatrix(scnMatrix4: SCNMatrix4($0))
        }
    }
}
