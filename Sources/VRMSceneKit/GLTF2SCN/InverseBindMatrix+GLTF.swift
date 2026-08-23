import VRMKit
import SceneKit

typealias InverseBindMatrix = NSValue

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension Array where Element == InverseBindMatrix {
    init(accessor: PackedAccessor) throws {
        guard accessor.componentType == .float else {
            throw VRMError._dataInconsistent("inverseBindMatrices must be a float MAT4 accessor")
        }
        // glTF stores matrices column-major, which is also SCNMatrix4's layout.
        let components = try accessor.floatComponents(.MAT4)
        self = try stride(from: 0, to: components.count, by: 16).map {
            InverseBindMatrix(scnMatrix4: try SCNMatrix4([Float](components[$0..<$0 + 16])))
        }
    }
}
