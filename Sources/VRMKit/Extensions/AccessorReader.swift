#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat

/// One glTF accessor read element by element where its buffer view holds it.
///
/// Nothing is copied out of the buffer: an element is found by stepping over the view's
/// stride, or among the sparse values when a substitution names it. A read costs only the
/// elements it asks for, so a primitive drawing part of a vertex buffer it shares with
/// others reads just its own vertices.
package struct AccessorReader: Sendable {
    package let accessor: GLTF.Accessor
    /// Where the elements are read from: the buffer view, or for an accessor without one, a
    /// single zero element that a zero stride repeats.
    private let base: Data
    private let byteOffset: Int
    private let byteStride: Int
    private let sparse: SparseSubstitution?
    private let componentsPerElement: Int
    private let bytesPerComponent: Int

    package var count: Int { accessor.count }
    package var componentType: GLTF.Accessor.ComponentType { accessor.componentType }
    package var normalized: Bool { accessor.normalized }

    /// Checks that every element lies inside its buffer view and that a sparse substitution
    /// names each element at most once, in order, so that reading afterwards cannot fail.
    package init(accessor: GLTF.Accessor, bufferView provider: BufferViewProvider) throws {
        let (componentsPerElement, bytesPerComponent, _) = accessor.components()
        let elementSize = try accessor.unpaddedVectorSize()
        self.accessor = accessor
        self.componentsPerElement = componentsPerElement
        self.bytesPerComponent = bytesPerComponent
        if let bufferView = accessor.bufferView {
            let source = try provider(bufferView)
            byteStride = source.stride ?? elementSize
            try source.bufferView.validateElements(offset: accessor.byteOffset, size: elementSize,
                                                   stride: byteStride, count: accessor.count)
            base = source.bufferView
            byteOffset = accessor.byteOffset
        } else {
            try Self.validateZeroFilled(count: accessor.count, elementSize: elementSize)
            base = Data(count: elementSize)
            byteOffset = 0
            byteStride = 0
        }
        if let sparse = accessor.sparse, sparse.count > 0 {
            self.sparse = try SparseSubstitution(sparse, elementCount: accessor.count,
                                                 elementSize: elementSize, provider: provider)
        } else {
            sparse = nil
        }
    }

    /// The most an accessor with no bufferView may zero-fill. Nothing in the document bounds
    /// the `count` such an accessor declares, and reading one decodes that many zeros into an
    /// array. 64 MiB is a million vertices of position and normal, far above what a real
    /// asset zero-fills.
    package static let maximumZeroFilledByteCount = 1 << 26

    private static func validateZeroFilled(count: Int, elementSize: Int) throws {
        guard count >= 0, elementSize > 0 else {
            throw VRMError._dataInconsistent("invalid accessor size (count: \(count), size: \(elementSize))")
        }
        let byteCount = elementSize.multipliedReportingOverflow(by: count)
        guard !byteCount.overflow else {
            throw VRMError._dataInconsistent("accessor size overflows (count: \(count), size: \(elementSize))")
        }
        guard byteCount.partialValue <= maximumZeroFilledByteCount else {
            throw VRMError._dataInconsistent(
                "an accessor with no bufferView asks to zero-fill \(byteCount.partialValue) bytes, "
                + "past the \(maximumZeroFilledByteCount) byte limit"
            )
        }
    }

    package func validate(_ type: GLTF.Accessor.`Type`) throws {
        guard accessor.type == type else {
            throw VRMError._dataInconsistent("expected \(type) accessor, got \(accessor.type)")
        }
    }

    /// Hands `body` where each element's bytes start.
    package func withElements<Result>(_ body: (ElementLocations) throws -> Result) rethrows -> Result {
        try base.withUnsafeBytes { baseBytes in
            let start = baseBytes.baseAddress.map { $0 + byteOffset }
            guard let sparse else {
                return try body(ElementLocations(start: start, stride: byteStride, sparse: nil))
            }
            return try sparse.withLocations { substituted in
                try body(ElementLocations(start: start, stride: byteStride, sparse: substituted))
            }
        }
    }

    /// Where each element of an accessor starts, valid only inside ``withElements(_:)``.
    package struct ElementLocations {
        fileprivate let start: UnsafeRawPointer?
        fileprivate let stride: Int
        fileprivate let sparse: SparseSubstitution.Locations?

        /// - Precondition: `element` is below the accessor's count.
        package subscript(element: Int) -> UnsafeRawPointer {
            if let substituted = sparse?.values(of: element) { return substituted }
            // The view was checked to hold every element, so it is empty only when none are read.
            return start! + element * stride
        }
    }

    /// Builds one value per element at `sources`, or per element in order when it is nil.
    /// `make` receives a reader for the element's components as floats, decoding normalized
    /// integer storage.
    ///
    /// - Precondition: every source is below ``count``.
    package func floatElements<Element>(_ type: GLTF.Accessor.`Type`,
                                        at sources: [UInt32]? = nil,
                                        make: (_ component: (Int) -> Float) -> Element) throws -> [Element] {
        try validate(type)
        // Fast path: plain floats load directly, without dispatching per component.
        if componentType == .float {
            return elements(at: sources) { element in
                make { element.loadUnaligned(fromByteOffset: 4 * $0, as: Float.self) }
            }
        }
        return elements(at: sources) { element in
            make { accessor.floatComponent(base: element, offset: bytesPerComponent * $0) }
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
                                           at sources: [UInt32]? = nil,
                                           make: (_ component: (Int) -> UInt32) -> Element) throws -> [Element] {
        try validate(type)
        let reader = try unsignedReader()
        return elements(at: sources) { element in
            make { reader.load(base: element, offset: bytesPerComponent * $0) }
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
        return [Float](unsafeUninitializedCapacity: total) { buffer, initialized in
            if let destination = buffer.baseAddress {
                writeFloatComponents(at: nil, to: destination)
            }
            initialized = total
        }
    }

    /// Writes the components of the elements at `sources`, or of every element in order when
    /// it is nil, one after another as floats from `destination` on.
    ///
    /// - Precondition: `destination` has room for them, and every source is below ``count``.
    package func writeFloatComponents(at sources: [UInt32]?, to destination: UnsafeMutablePointer<Float>) {
        let elementSize = componentsPerElement * bytesPerComponent
        // Tightly packed floats are already the little-endian bytes of the result: one copy.
        if sources == nil, sparse == nil, componentType == .float, byteStride == elementSize {
            guard count > 0 else { return }
            base.withUnsafeBytes { raw in
                if let start = raw.baseAddress {
                    memcpy(destination, start + byteOffset, count * elementSize)
                }
            }
            return
        }
        withElements { elements in
            var next = destination
            func write(_ element: UnsafeRawPointer) {
                for component in 0..<componentsPerElement {
                    next.initialize(to: accessor.floatComponent(base: element, offset: bytesPerComponent * component))
                    next += 1
                }
            }
            if let sources {
                for source in sources {
                    write(elements[Self.checked(source, below: count)])
                }
            } else {
                for index in 0..<count {
                    write(elements[index])
                }
            }
        }
    }

    private func unsignedReader() throws -> UnsignedComponentReader {
        try UnsignedComponentReader(componentType)
            ??? ._dataInconsistent("expected an unsigned integer accessor, got \(componentType) components")
    }

    private func elements<Element>(at sources: [UInt32]?, _ make: (UnsafeRawPointer) -> Element) -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(sources?.count ?? count)
        withElements { elements in
            if let sources {
                for source in sources {
                    result.append(make(elements[Self.checked(source, below: count)]))
                }
            } else {
                for index in 0..<count {
                    result.append(make(elements[index]))
                }
            }
        }
        return result
    }

    private static func checked(_ source: UInt32, below count: Int) -> Int {
        let index = Int(source)
        precondition(index < count, "element \(index) is out of range for \(count) accessor elements")
        return index
    }
}

/// The skinning attributes, whose component types glTF constrains further.
package extension AccessorReader {
    /// `JOINTS_n` as glTF defines it: unsigned byte or short indices into the skin.
    func validateJointIndices() throws {
        switch componentType {
        case .unsignedByte, .unsignedShort:
            try validate(.VEC4)
        case .byte, .short, .unsignedInt, .float:
            throw VRMError._dataInconsistent(
                "JOINTS_0 must use unsigned byte or short components, not \(componentType)"
            )
        }
    }

    func jointIndices(at sources: [UInt32]? = nil) throws -> [SIMD4<UInt32>] {
        try validateJointIndices()
        return try unsignedElements(.VEC4, at: sources) { SIMD4<UInt32>($0(0), $0(1), $0(2), $0(3)) }
    }

    /// `WEIGHTS_n` as glTF defines it: float, or normalized unsigned byte / short.
    func validateJointWeights() throws {
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
        try validate(.VEC4)
    }

    func jointWeights(at sources: [UInt32]? = nil) throws -> [SIMD4<Float>] {
        try validateJointWeights()
        return try floatElements(.VEC4, at: sources) { SIMD4<Float>($0(0), $0(1), $0(2), $0(3)) }
    }
}

/// The elements a sparse accessor substitutes, read where the document stores them.
private struct SparseSubstitution: Sendable {
    let count: Int
    let indices: Data
    let indexOffset: Int
    let indexStride: Int
    let indexReader: UnsignedComponentReader
    let values: Data
    let valueOffset: Int
    let valueStride: Int

    init(_ sparse: GLTF.Accessor.Sparse, elementCount: Int, elementSize: Int, provider: BufferViewProvider) throws {
        guard let indexReader = UnsignedComponentReader(sparse.indices.componentType) else {
            throw VRMError._dataInconsistent(
                "sparse indices cannot use \(sparse.indices.componentType) components"
            )
        }
        let indexSource = try provider(sparse.indices.bufferView)
        let bytesPerIndex = bytes(of: sparse.indices.componentType)
        let indexStride = indexSource.stride ?? bytesPerIndex
        try indexSource.bufferView.validateElements(offset: sparse.indices.byteOffset, size: bytesPerIndex,
                                                    stride: indexStride, count: sparse.count)
        try Self.validateIndices(in: indexSource.bufferView, offset: sparse.indices.byteOffset, stride: indexStride,
                                 reader: indexReader, count: sparse.count, elementCount: elementCount)
        let valueSource = try provider(sparse.values.bufferView)
        let valueStride = valueSource.stride ?? elementSize
        try valueSource.bufferView.validateElements(offset: sparse.values.byteOffset, size: elementSize,
                                                    stride: valueStride, count: sparse.count)
        count = sparse.count
        indices = indexSource.bufferView
        indexOffset = sparse.indices.byteOffset
        self.indexStride = indexStride
        self.indexReader = indexReader
        values = valueSource.bufferView
        valueOffset = sparse.values.byteOffset
        self.valueStride = valueStride
    }

    /// Strictly increasing indices are what makes the substitution unambiguous, and what
    /// lets a read find an element by binary search.
    private static func validateIndices(in indices: Data, offset: Int, stride: Int, reader: UnsignedComponentReader,
                                        count: Int, elementCount: Int) throws {
        var outOfRange: Int?
        var isIncreasing = true
        indices.withUnsafeBytes { raw in
            guard let start = raw.baseAddress.map({ $0 + offset }) else { return }
            var previous = -1
            for position in 0..<count {
                let value = Int(reader.load(base: start, offset: position * stride))
                if outOfRange == nil, value >= elementCount {
                    outOfRange = value
                }
                isIncreasing = isIncreasing && value > previous
                previous = value
            }
        }
        if let outOfRange {
            throw VRMError._dataInconsistent(
                "sparse index \(outOfRange) is out of range for \(elementCount) accessor elements"
            )
        }
        guard isIncreasing else {
            throw VRMError._dataInconsistent("sparse indices must be strictly increasing")
        }
    }

    func withLocations<Result>(_ body: (Locations) throws -> Result) rethrows -> Result {
        try indices.withUnsafeBytes { indexBytes in
            try values.withUnsafeBytes { valueBytes in
                // Both views were checked to hold `count` > 0 elements.
                try body(Locations(count: count,
                                   indices: indexBytes.baseAddress! + indexOffset,
                                   indexStride: indexStride,
                                   indexReader: indexReader,
                                   values: valueBytes.baseAddress! + valueOffset,
                                   valueStride: valueStride))
            }
        }
    }

    struct Locations {
        let count: Int
        let indices: UnsafeRawPointer
        let indexStride: Int
        let indexReader: UnsignedComponentReader
        let values: UnsafeRawPointer
        let valueStride: Int

        /// Where the substituted bytes of `element` start, or nil for an element the
        /// substitution leaves alone.
        func values(of element: Int) -> UnsafeRawPointer? {
            var low = 0
            var high = count
            while low < high {
                let middle = (low + high) / 2
                let index = Int(indexReader.load(base: indices, offset: middle * indexStride))
                if index == element { return values + middle * valueStride }
                if index < element {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return nil
        }
    }
}

/// Accessors resolved once and reused: resolving one checks its layout and its sparse
/// indices, which readers sharing the accessor then skip.
///
/// Owned by whatever needs the decoded geometry. Locked because a load decodes
/// primitives in parallel.
package final class AccessorReaderCache: Sendable {
    private let document: GLTFDocument
    private let readers = Locked<[Int: AccessorReader]>([:])

    package init(document: GLTFDocument) {
        self.document = document
    }

    package func accessor(at index: Int) throws -> AccessorReader {
        if let cached = readers.withLock({ $0[index] }) { return cached }
        // Resolved outside the lock: two tasks racing on one accessor agree on the result.
        let reader = try AccessorReader(accessor: document.gltf.load(\.accessors, at: index),
                                        bufferView: document.bufferViewProvider)
        readers.withLock { $0[index] = reader }
        return reader
    }

    /// A sampler input. The spec fixes it to FLOAT scalars that start at or after zero
    /// and increase strictly.
    package func animationTimes(at index: Int) throws -> [Float] {
        let accessor = try accessor(at: index)
        guard accessor.componentType == .float else {
            throw VRMError._dataInconsistent(
                "an animation sampler input must be a FLOAT accessor, got \(accessor.componentType)"
            )
        }
        let times = try accessor.floatComponents(.SCALAR)
        guard times.first.map({ $0 >= 0 }) != false else {
            throw VRMError._dataInconsistent("animation sampler input times must start at or after 0")
        }
        return times
    }

    /// The animation's length: the last keyframe time any of its samplers holds. Read
    /// from the times themselves rather than the accessor's `max`, which a file may
    /// leave out or disagree with. A sampler whose times cannot be read counts for nothing.
    package func duration(of animation: GLTF.Animation) -> TimeInterval {
        var duration: Float = 0
        for input in Set(animation.samplers.map(\.input)) {
            if let last = try? animationTimes(at: input).last {
                duration = max(duration, last)
            }
        }
        return TimeInterval(duration)
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
