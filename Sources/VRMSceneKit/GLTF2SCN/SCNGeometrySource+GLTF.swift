import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNGeometrySource {
    convenience init(accessor: GLTF.Accessor, semantic: SCNGeometrySource.Semantic, loader: VRMSceneLoader) throws {
        let (componentsPerVector, bytesPerComponent, vectorSize) = accessor.components()
        if let sparse = accessor.sparse {
            var data = try baseDataForSparse(accessor: accessor, vectorSize: vectorSize, loader: loader)
            try applySparse(sparse: sparse,
                            accessorCount: accessor.count,
                            vectorSize: vectorSize,
                            loader: loader,
                            data: &data)
            self.init(data: data,
                      semantic: semantic,
                      vectorCount: accessor.count,
                      usesFloatComponents: accessor.componentType == .float,
                      componentsPerVector: componentsPerVector,
                      bytesPerComponent: bytesPerComponent,
                      dataOffset: 0,
                      dataStride: vectorSize)
        } else {
            let (bufferView, dataStride): (Data, Int) = try {
                if let bufferViewIndex = accessor.bufferView {
                    let bufferView = try loader.bufferView(withBufferViewIndex: bufferViewIndex)
                    return (bufferView.bufferView, bufferView.stride ?? vectorSize)
                } else {
                    return (Data(count: vectorSize * accessor.count), vectorSize)
                }
            }()

            self.init(data: bufferView,
                      semantic: semantic,
                      vectorCount: accessor.count,
                      usesFloatComponents: accessor.componentType == .float,
                      componentsPerVector: componentsPerVector,
                      bytesPerComponent: bytesPerComponent,
                      dataOffset: accessor.byteOffset,
                      dataStride: dataStride)
        }
    }
}

private func baseDataForSparse(accessor: GLTF.Accessor,
                               vectorSize: Int,
                               loader: VRMSceneLoader) throws -> Data {
    if let bufferViewIndex = accessor.bufferView {
        let bufferView = try loader.bufferView(withBufferViewIndex: bufferViewIndex)
        let dataStride = bufferView.stride ?? vectorSize
        return bufferView.bufferView.subdata(offset: accessor.byteOffset,
                                             size: vectorSize,
                                             stride: dataStride,
                                             count: accessor.count)
    }
    return Data(count: vectorSize * accessor.count)
}

private func applySparse(sparse: GLTF.Accessor.Sparse,
                         accessorCount: Int,
                         vectorSize: Int,
                         loader: VRMSceneLoader,
                         data: inout Data) throws {
    guard sparse.count > 0 else { return }
    let indices = try sparseIndices(sparse: sparse, loader: loader)
    let values = try sparseValues(sparse: sparse, vectorSize: vectorSize, loader: loader)
    let count = min(indices.count, sparse.count)
    data.withUnsafeMutableBytes { rawDst in
        guard let dst = rawDst.bindMemory(to: UInt8.self).baseAddress else { return }
        values.withUnsafeBytes { rawSrc in
            guard let src = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<count {
                let index = indices[i]
                guard index >= 0, index < accessorCount else { continue }
                let dstPos = index * vectorSize
                let srcPos = i * vectorSize
                memcpy(dst.advanced(by: dstPos), src.advanced(by: srcPos), vectorSize)
            }
        }
    }
}

private func sparseIndices(sparse: GLTF.Accessor.Sparse, loader: VRMSceneLoader) throws -> [Int] {
    let bufferView = try loader.bufferView(withBufferViewIndex: sparse.indices.bufferView)
    let bytesPerIndex = bytes(of: sparse.indices.componentType)
    let stride = bufferView.stride ?? bytesPerIndex
    let indexData = bufferView.bufferView.subdata(offset: sparse.indices.byteOffset,
                                                  size: bytesPerIndex,
                                                  stride: stride,
                                                  count: sparse.count)
    var indices: [Int] = []
    indices.reserveCapacity(sparse.count)
    indexData.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        for i in 0..<sparse.count {
            let offset = i * bytesPerIndex
            switch sparse.indices.componentType {
            case .unsignedByte:
                indices.append(Int(base.load(fromByteOffset: offset, as: UInt8.self)))
            case .unsignedShort:
                indices.append(Int(base.load(fromByteOffset: offset, as: UInt16.self)))
            case .unsignedInt:
                indices.append(Int(base.load(fromByteOffset: offset, as: UInt32.self)))
            default:
                break
            }
        }
    }
    return indices
}

private func sparseValues(sparse: GLTF.Accessor.Sparse,
                          vectorSize: Int,
                          loader: VRMSceneLoader) throws -> Data {
    let bufferView = try loader.bufferView(withBufferViewIndex: sparse.values.bufferView)
    let stride = bufferView.stride ?? vectorSize
    return bufferView.bufferView.subdata(offset: sparse.values.byteOffset,
                                         size: vectorSize,
                                         stride: stride,
                                         count: sparse.count)
}
