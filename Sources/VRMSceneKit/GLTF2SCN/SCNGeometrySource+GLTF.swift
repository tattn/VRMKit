import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNGeometrySource {
    convenience init(accessor: GLTF.Accessor, semantic: SCNGeometrySource.Semantic, loader: VRMSceneLoader) throws {
        let (componentsPerVector, bytesPerComponent, vectorSize) = accessor.components()
        let data = try accessor.packedData(bufferView: { try loader.bufferView(withBufferViewIndex: $0) })
        self.init(data: data,
                  semantic: semantic,
                  vectorCount: accessor.count,
                  usesFloatComponents: accessor.componentType == .float,
                  componentsPerVector: componentsPerVector,
                  bytesPerComponent: bytesPerComponent,
                  dataOffset: 0,
                  dataStride: vectorSize)
    }
}
