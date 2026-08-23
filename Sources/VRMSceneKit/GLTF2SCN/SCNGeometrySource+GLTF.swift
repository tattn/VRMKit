import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNGeometrySource {
    /// glTF stores `TEXCOORD_n`, `WEIGHTS_n` and `COLOR_n` as floats or as
    /// normalized integers, while a source SceneKit is told holds integers is
    /// read as plain integers rather than as the fractions those stand for. So
    /// everything but the joint references, which `SCNSkinner` wants as
    /// integers, is expanded to floats.
    convenience init(accessor: PackedAccessor, semantic: SCNGeometrySource.Semantic) {
        let usesFloatComponents = semantic != .boneIndices
        let expandsToFloats = usesFloatComponents && accessor.componentType != .float
        let bytesPerComponent = expandsToFloats ? MemoryLayout<Float>.size : accessor.bytesPerComponent
        self.init(data: expandsToFloats
                    ? accessor.floatComponents().withUnsafeBufferPointer { Data(buffer: $0) }
                    : accessor.data,
                  semantic: semantic,
                  vectorCount: accessor.count,
                  usesFloatComponents: usesFloatComponents,
                  componentsPerVector: accessor.componentsPerElement,
                  bytesPerComponent: bytesPerComponent,
                  dataOffset: 0,
                  // An expanded accessor is tightly packed.
                  dataStride: accessor.componentsPerElement * bytesPerComponent)
    }
}
