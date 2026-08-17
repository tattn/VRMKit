import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNGeometryElement {
    convenience init(accessor: GLTF.Accessor, mode: GLTF.Mesh.Primitive.Mode, loader: VRMSceneLoader) throws {
        let primitiveType = try primitiveTypeOf(mode) ??? ._notSupported("\(mode) is not supported")
        let usesFloatComponents = accessor.componentType == .float
        let bytesPerComponent = bytes(of: accessor.componentType)

        if usesFloatComponents { throw VRMError._dataInconsistent("index accessor cannot use float components") }
        if accessor.type != .SCALAR { throw VRMError._dataInconsistent("accessor type is not SCALAR") }

        self.init(data: try accessor.packedData(bufferView: { try loader.bufferView(withBufferViewIndex: $0) }),
                  primitiveType: primitiveType,
                  primitiveCount: primitiveType.primitiveCount(ofCount: accessor.count),
                  bytesPerIndex: bytesPerComponent)
    }
}
