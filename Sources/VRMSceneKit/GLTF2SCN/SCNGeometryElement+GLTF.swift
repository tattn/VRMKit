import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNGeometryElement {
    convenience init(accessor: PackedAccessor, mode: GLTF.Mesh.Primitive.Mode) throws {
        let primitiveType = try primitiveTypeOf(mode) ??? ._notSupported("\(mode) is not supported")
        // `unsignedData` checks the unsigned scalars glTF requires of indices.
        self.init(data: try accessor.unsignedData(.SCALAR),
                  primitiveType: primitiveType,
                  primitiveCount: primitiveType.primitiveCount(ofCount: accessor.count),
                  bytesPerIndex: accessor.bytesPerComponent)
    }
}
