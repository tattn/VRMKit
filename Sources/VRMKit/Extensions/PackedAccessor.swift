import Foundation
import simd

/// One glTF accessor expanded into tightly packed elements.
///
/// Expanding removes the buffer view's stride and applies the sparse substitution,
/// so it is done once here and every reader works off the result.
package struct PackedAccessor: Sendable {
    package let accessor: GLTF.Accessor
    package let data: Data
    private let componentsPerElement: Int
    private let bytesPerComponent: Int

    package var count: Int { accessor.count }
    package var componentType: GLTF.Accessor.ComponentType { accessor.componentType }
    package var normalized: Bool { accessor.normalized }

    package init(accessor: GLTF.Accessor, bufferView provider: BufferViewProvider) throws {
        let (componentsPerElement, bytesPerComponent, _) = accessor.components()
        self.accessor = accessor
        self.data = try accessor.packedData(bufferView: provider)
        self.componentsPerElement = componentsPerElement
        self.bytesPerComponent = bytesPerComponent
    }

    /// Builds one value per accessor element. `make` receives a reader for the
    /// element's components as floats, decoding normalized integer storage.
    package func floatElements<Element>(_ type: GLTF.Accessor.`Type`,
                                        make: (_ component: (Int) -> Float) -> Element) throws -> [Element] {
        try validate(type)
        // Fast path: plain floats load directly, without dispatching per component.
        if componentType == .float {
            return elements { base, elementOffset in
                make { component in
                    base.loadUnaligned(fromByteOffset: elementOffset + 4 * component, as: Float.self)
                }
            }
        }
        return elements { base, elementOffset in
            make { component in
                accessor.floatComponent(base: base, offset: elementOffset + bytesPerComponent * component)
            }
        }
    }

    /// Float MAT4 elements in glTF's column-major order.
    package func float4x4Elements() throws -> [simd_float4x4] {
        guard componentType == .float else {
            throw VRMError._dataInconsistent("MAT4 accessor must be float")
        }
        return try floatElements(.MAT4) { component in
            simd_float4x4(columns: (
                SIMD4<Float>(component(0), component(1), component(2), component(3)),
                SIMD4<Float>(component(4), component(5), component(6), component(7)),
                SIMD4<Float>(component(8), component(9), component(10), component(11)),
                SIMD4<Float>(component(12), component(13), component(14), component(15))
            ))
        }
    }

    /// The same, reading the components as unsigned integers.
    package func unsignedElements<Element>(_ type: GLTF.Accessor.`Type`,
                                           make: (_ component: (Int) -> UInt32) -> Element) throws -> [Element] {
        try validate(type)
        let reader = try unsignedReader()
        return elements { base, elementOffset in
            make { component in
                reader.load(base: base, offset: elementOffset + bytesPerComponent * component)
            }
        }
    }

    /// Every component of every element of a `type` accessor, in order.
    package func floatComponents(_ type: GLTF.Accessor.`Type`) throws -> [Float] {
        try validate(type)
        return floatComponents()
    }

    /// The same, whatever element type the accessor holds.
    package func floatComponents() -> [Float] {
        let total = count * componentsPerElement
        // Packed float storage is already the little-endian bytes of the result: one copy.
        if componentType == .float {
            return [Float](unsafeUninitializedCapacity: total) { buffer, initialized in
                guard let destination = buffer.baseAddress else { return }
                let expected = total * MemoryLayout<Float>.size
                data.withUnsafeBytes { raw in
                    let bytes = min(expected, raw.count)
                    if bytes > 0, let base = raw.baseAddress {
                        memcpy(destination, base, bytes)
                    }
                    // Packed data always covers the accessor; zero any short tail all the same.
                    if bytes < expected {
                        memset(UnsafeMutableRawPointer(destination).advanced(by: bytes), 0, expected - bytes)
                    }
                }
                initialized = total
            }
        }
        var result = [Float](repeating: 0, count: total)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in result.indices {
                result[index] = accessor.floatComponent(base: base, offset: index * bytesPerComponent)
            }
        }
        return result
    }

    private func unsignedReader() throws -> UnsignedComponentReader {
        try UnsignedComponentReader(componentType)
            ??? ._dataInconsistent("expected an unsigned integer accessor, got \(componentType) components")
    }

    private func validate(_ type: GLTF.Accessor.`Type`) throws {
        guard accessor.type == type else {
            throw VRMError._dataInconsistent("expected \(type) accessor, got \(accessor.type)")
        }
    }

    private func elements<Element>(_ make: (UnsafeRawPointer, Int) -> Element) -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in 0..<count {
                result.append(make(base, index * componentsPerElement * bytesPerComponent))
            }
        }
        return result
    }
}

/// The skinning attributes, whose component types glTF constrains further.
package extension PackedAccessor {
    /// `JOINTS_n` as glTF defines it: unsigned byte or short indices into the skin.
    func jointIndices() throws -> [SIMD4<UInt32>] {
        switch componentType {
        case .unsignedByte, .unsignedShort:
            return try unsignedElements(.VEC4) { SIMD4<UInt32>($0(0), $0(1), $0(2), $0(3)) }
        case .byte, .short, .unsignedInt, .float:
            throw VRMError._dataInconsistent(
                "JOINTS_0 must use unsigned byte or short components, not \(componentType)"
            )
        }
    }

    /// `WEIGHTS_n` as glTF defines it: float, or normalized unsigned byte / short.
    func jointWeights() throws -> [SIMD4<Float>] {
        switch componentType {
        case .float:
            break
        case .unsignedByte, .unsignedShort:
            guard normalized else {
                throw VRMError._dataInconsistent(
                    "WEIGHTS_0 with \(componentType) components must be normalized"
                )
            }
        case .byte, .short, .unsignedInt:
            throw VRMError._dataInconsistent(
                "WEIGHTS_0 must use float or normalized unsigned byte / short components, "
                + "not \(componentType)"
            )
        }
        return try floatElements(.VEC4) { SIMD4<Float>($0(0), $0(1), $0(2), $0(3)) }
    }
}

/// Accessors expanded once and reused, so readers sharing one accessor expand it a single time.
///
/// Owned by whatever needs the decoded geometry. Locked because a load expands
/// primitives in parallel.
package final class PackedAccessorCache: Sendable {
    private let document: GLTFDocument
    private let packedAccessors = Locked<[Int: PackedAccessor]>([:])

    package init(document: GLTFDocument) {
        self.document = document
    }

    package func accessor(at index: Int) throws -> PackedAccessor {
        if let cached = packedAccessors.withLock({ $0[index] }) { return cached }
        // Expanded outside the lock: two tasks racing on one accessor agree on the result.
        let packed = try PackedAccessor(accessor: document.gltf.load(\.accessors, at: index),
                                        bufferView: document.bufferViewProvider)
        packedAccessors.withLock { $0[index] = packed }
        return packed
    }

    /// Drops the expanded accessors, for a reader that is done with them.
    package func removeAll() {
        packedAccessors.withLock { $0 = [:] }
    }

    /// Expands a float-valued accessor of `type` element by element.
    package func floatElements<Element>(at index: Int,
                                        type: GLTF.Accessor.`Type`,
                                        make: (_ component: (Int) -> Float) -> Element) throws -> [Element] {
        try accessor(at: index).floatElements(type, make: make)
    }
}

/// The component types glTF allows where a value is an unsigned integer.
private enum UnsignedComponentReader {
    case unsignedByte
    case unsignedShort
    case unsignedInt

    init?(_ componentType: GLTF.Accessor.ComponentType) {
        switch componentType {
        case .unsignedByte: self = .unsignedByte
        case .unsignedShort: self = .unsignedShort
        case .unsignedInt: self = .unsignedInt
        case .byte, .short, .float: return nil
        }
    }

    func load(base: UnsafeRawPointer, offset: Int) -> UInt32 {
        switch self {
        case .unsignedByte: return UInt32(base.load(fromByteOffset: offset, as: UInt8.self))
        case .unsignedShort: return UInt32(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        case .unsignedInt: return base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }
}
