import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#accessor

/// Reads the bytes and stride of a glTF buffer view. Both loaders cache buffer
/// views on their own scene data, so accessor expansion goes through this.
package typealias BufferViewProvider = (Int) throws -> (bufferView: Data, stride: Int?)

package func numberOfComponents(of type: GLTF.Accessor.`Type`) -> Int {
    switch type {
    case .SCALAR: return 1
    case .VEC2: return 2
    case .VEC3: return 3
    case .VEC4: return 4
    case .MAT2: return 4
    case .MAT3: return 9
    case .MAT4: return 16
    }
}

package func bytes(of type: GLTF.Accessor.ComponentType) -> Int {
    switch type {
    case .byte, .unsignedByte: return 1
    case .short, .unsignedShort: return 2
    case .unsignedInt, .float: return 4
    }
}

package extension GLTF.Accessor {
    func components() -> (componentsPerVector: Int, bytesPerComponent: Int, vectorSize: Int) {
        let componentsPerVector = numberOfComponents(of: type)
        let bytesPerComponent = bytes(of: componentType)
        let vectorSize = bytesPerComponent * componentsPerVector
        return (componentsPerVector, bytesPerComponent, vectorSize)
    }

    /// One component as a float. `normalized` accessors map integers onto [0, 1]
    /// or [-1, 1], with the signed minimum clamped to -1 per spec.
    func floatComponent(base: UnsafeRawPointer, offset: Int) -> Float {
        switch componentType {
        case .float:
            return base.loadUnaligned(fromByteOffset: offset, as: Float.self)
        case .unsignedByte:
            let value = Float(base.load(fromByteOffset: offset, as: UInt8.self))
            return normalized ? value / Float(UInt8.max) : value
        case .byte:
            let value = Float(base.load(fromByteOffset: offset, as: Int8.self))
            return normalized ? Swift.max(-1, value / Float(Int8.max)) : value
        case .unsignedShort:
            let value = Float(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            return normalized ? value / Float(UInt16.max) : value
        case .short:
            let value = Float(base.loadUnaligned(fromByteOffset: offset, as: Int16.self))
            return normalized ? Swift.max(-1, value / Float(Int16.max)) : value
        case .unsignedInt:
            let value = Float(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            return normalized ? value / Float(UInt32.max) : value
        }
    }

    /// The accessor's elements as tightly packed data: any buffer view stride is
    /// removed, an accessor without a buffer view yields the zeroes the spec
    /// defines for it, and a sparse substitution is applied on top.
    func packedData(bufferView provider: BufferViewProvider) throws -> Data {
        let vectorSize = try unpaddedVectorSize()
        var data = try packedBaseData(vectorSize: vectorSize, provider: provider)
        if let sparse {
            try apply(sparse, vectorSize: vectorSize, provider: provider, to: &data)
        }
        return data
    }
}

private extension GLTF.Accessor {
    /// The element size, rejecting the matrix layouts glTF pads. MAT2 / MAT3
    /// columns are aligned to 4 bytes, so with small component types an element
    /// is wider than its components — a layout no VRM asset uses, and one the
    /// readers above would mis-slice.
    func unpaddedVectorSize() throws -> Int {
        let (componentsPerVector, bytesPerComponent, vectorSize) = components()
        let columnCount: Int
        switch type {
        case .SCALAR, .VEC2, .VEC3, .VEC4: return vectorSize
        case .MAT2: columnCount = 2
        case .MAT3: columnCount = 3
        case .MAT4: columnCount = 4
        }
        let columnSize = bytesPerComponent * (componentsPerVector / columnCount)
        guard columnSize.isMultiple(of: 4) else {
            throw VRMError._notSupported(
                "\(type) accessors with \(componentType) components pad their columns, which is not supported"
            )
        }
        return vectorSize
    }

    func packedBaseData(vectorSize: Int, provider: BufferViewProvider) throws -> Data {
        guard let bufferView else {
            return try Data(zeroedElementCount: count, elementSize: vectorSize)
        }
        let source = try provider(bufferView)
        return try source.bufferView.subdata(offset: byteOffset,
                                             size: vectorSize,
                                             stride: source.stride ?? vectorSize,
                                             count: count)
    }

    func apply(_ sparse: Sparse,
               vectorSize: Int,
               provider: BufferViewProvider,
               to data: inout Data) throws {
        guard sparse.count > 0 else { return }
        let indices = try sparseIndices(sparse, provider: provider)
        if let outOfRange = indices.first(where: { $0 < 0 || $0 >= count }) {
            throw VRMError._dataInconsistent(
                "sparse index \(outOfRange) is out of range for \(count) accessor elements"
            )
        }
        // Strictly increasing indices are what makes the substitution below
        // unambiguous: repeated ones would leave the element they overlap on
        // depending on the copy order.
        guard zip(indices, indices.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw VRMError._dataInconsistent("sparse indices must be strictly increasing")
        }
        let values = try sparseValues(sparse, vectorSize: vectorSize, provider: provider)
        data.withUnsafeMutableBytes { rawDst in
            guard let dst = rawDst.bindMemory(to: UInt8.self).baseAddress else { return }
            values.withUnsafeBytes { rawSrc in
                guard let src = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return }
                for (position, index) in indices.enumerated() {
                    memcpy(dst.advanced(by: index * vectorSize),
                           src.advanced(by: position * vectorSize),
                           vectorSize)
                }
            }
        }
    }

    func sparseIndices(_ sparse: Sparse, provider: BufferViewProvider) throws -> [Int] {
        switch sparse.indices.componentType {
        case .unsignedByte, .unsignedShort, .unsignedInt: break
        case .byte, .short, .float:
            throw VRMError._dataInconsistent(
                "sparse indices cannot use \(sparse.indices.componentType) components"
            )
        }
        let source = try provider(sparse.indices.bufferView)
        let bytesPerIndex = bytes(of: sparse.indices.componentType)
        let indexData = try source.bufferView.subdata(offset: sparse.indices.byteOffset,
                                                      size: bytesPerIndex,
                                                      stride: source.stride ?? bytesPerIndex,
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
                default:
                    indices.append(Int(base.load(fromByteOffset: offset, as: UInt32.self)))
                }
            }
        }
        return indices
    }

    func sparseValues(_ sparse: Sparse, vectorSize: Int, provider: BufferViewProvider) throws -> Data {
        let source = try provider(sparse.values.bufferView)
        return try source.bufferView.subdata(offset: sparse.values.byteOffset,
                                             size: vectorSize,
                                             stride: source.stride ?? vectorSize,
                                             count: sparse.count)
    }
}
