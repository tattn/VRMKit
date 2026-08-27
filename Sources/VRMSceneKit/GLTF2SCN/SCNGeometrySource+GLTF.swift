import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNGeometrySource {
    /// SceneKit reads an integer source as plain integers rather than as the
    /// fractions glTF's normalized ones stand for, so everything but the joint
    /// references, which `SCNSkinner` wants as integers, is expanded to floats.
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

    /// The same attribute with one vector per entry of `corners`, which unshares
    /// the vertices a triangle list points at.
    func expanded(to corners: [Int]) throws -> SCNGeometrySource {
        guard (corners.max() ?? -1) < vectorCount else {
            throw VRMError._dataInconsistent(
                "a \(semantic.rawValue) attribute holds \(vectorCount) vectors, fewer than the primitive draws"
            )
        }
        let vectorSize = componentsPerVector * bytesPerComponent
        var expanded = Data(count: corners.count * vectorSize)
        expanded.withUnsafeMutableBytes { rawDestination in
            guard let destination = rawDestination.baseAddress else { return }
            data.withUnsafeBytes { rawSource in
                guard let source = rawSource.baseAddress else { return }
                for (corner, vector) in corners.enumerated() {
                    memcpy(destination.advanced(by: corner * vectorSize),
                           source.advanced(by: dataOffset + dataStride * vector),
                           vectorSize)
                }
            }
        }
        return SCNGeometrySource(data: expanded,
                                 semantic: semantic,
                                 vectorCount: corners.count,
                                 usesFloatComponents: usesFloatComponents,
                                 componentsPerVector: componentsPerVector,
                                 bytesPerComponent: bytesPerComponent,
                                 dataOffset: 0,
                                 dataStride: vectorSize)
    }

    func createVertices() throws -> [SIMD3<Float>] {
        guard componentsPerVector == 3 else { throw VRMError._notSupported("vertex array is support for 3 component only: \(componentsPerVector)") }
        if !usesFloatComponents || bytesPerComponent != 4 { throw VRMError._notSupported("vertex array is support for float components only") }

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(vectorCount)
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.bindMemory(to: Float32.self).baseAddress else { return }
            var index = dataOffset / bytesPerComponent
            let step = dataStride / bytesPerComponent
            for _ in 0..<vectorCount {
                vertices.append(SIMD3<Float>(ptr[index], ptr[index + 1], ptr[index + 2]))
                index += step
            }
        }
        return vertices
    }
}
