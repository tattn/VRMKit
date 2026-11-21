#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#accessor

/// Reads the bytes and stride of a glTF buffer view.
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

    /// The element size, rejecting the matrix layouts glTF pads. MAT2 / MAT3
    /// columns are aligned to 4 bytes, so with small component types an element
    /// is wider than its components, a layout no VRM asset uses and one the
    /// readers would mis-slice.
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
}
