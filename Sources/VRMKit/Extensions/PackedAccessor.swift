import Foundation

/// One glTF accessor expanded into tightly packed elements, ready to be read as
/// floats or as the unsigned integers glTF uses for indices and joint references.
///
/// Expanding an accessor removes its buffer view's stride and applies its sparse
/// substitution, so it is done once here and every reader works off the result.
package struct PackedAccessor {
    package let accessor: GLTF.Accessor
    package let data: Data
    package let componentsPerElement: Int
    package let bytesPerComponent: Int

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
        return elements { base, elementOffset in
            make { component in
                accessor.floatComponent(base: base, offset: elementOffset + bytesPerComponent * component)
            }
        }
    }

    /// The same, reading the components as the unsigned integers glTF defines for
    /// indices and `JOINTS_n`.
    package func unsignedElements<Element>(_ type: GLTF.Accessor.`Type`,
                                           make: (_ component: (Int) -> UInt32) -> Element) throws -> [Element] {
        try validate(type)
        guard let reader = UnsignedComponentReader(componentType) else {
            throw VRMError._dataInconsistent(
                "expected an unsigned integer accessor, got \(componentType) components"
            )
        }
        return elements { base, elementOffset in
            make { component in
                reader.load(base: base, offset: elementOffset + bytesPerComponent * component)
            }
        }
    }

    /// Every component of every element of a `type` accessor, in order.
    package func floatComponents(_ type: GLTF.Accessor.`Type`) throws -> [Float] {
        try validate(type)
        var result = [Float](repeating: 0, count: count * componentsPerElement)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in result.indices {
                result[index] = accessor.floatComponent(base: base, offset: index * bytesPerComponent)
            }
        }
        return result
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

/// Accessors expanded once and reused, so the primitives, skins and animation
/// samplers that share one accessor expand it a single time.
///
/// A cache holds decoded geometry, so it belongs to whatever needs it (one
/// scene load, one animation binding) and is dropped with it.
package final class PackedAccessorCache {
    private let document: GLTFDocument
    private var packedAccessors: [Int: PackedAccessor] = [:]

    package init(document: GLTFDocument) {
        self.document = document
    }

    package func accessor(at index: Int) throws -> PackedAccessor {
        if let cached = packedAccessors[index] { return cached }
        let packed = try PackedAccessor(accessor: document.gltf.load(\.accessors, at: index),
                                        bufferView: document.bufferViewProvider)
        packedAccessors[index] = packed
        return packed
    }

    /// Expands a float-valued accessor of `type` element by element. `make`
    /// receives a reader for the element's components.
    package func floatElements<Element>(at index: Int,
                                        type: GLTF.Accessor.`Type`,
                                        make: (_ component: (Int) -> Float) -> Element) throws -> [Element] {
        try accessor(at: index).floatElements(type, make: make)
    }

    /// Every component of a `type` accessor, in order.
    package func floatComponents(at index: Int, type: GLTF.Accessor.`Type`) throws -> [Float] {
        try accessor(at: index).floatComponents(type)
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
