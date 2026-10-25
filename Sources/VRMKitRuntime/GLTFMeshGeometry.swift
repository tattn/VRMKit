#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat
import VRMKit

/// The vertex data behind one model entity of a loaded glTF, as authored: the rest
/// pose, before any skinning or morphing.
///
/// Plain arrays any renderer can upload, and where anything that needs to know where a
/// vertex sits reads it. Every slot of the merged mesh shares the one vertex array and
/// draws its own range of `indices`.
public struct GLTFMeshGeometry: Sendable {
    /// One material slot of the merged mesh, built from one glTF primitive.
    public struct Slot: Sendable {
        /// The vertices the slot's triangles reference.
        public let vertexRange: Range<Int>
        /// Where the slot's triangles sit in ``GLTFMeshGeometry/indices``.
        public let indexRange: Range<Int>
        /// Where the triangles a first-person camera draws sit in
        /// ``GLTFMeshGeometry/indices``. Nil draws the slot whole; an empty range
        /// draws nothing of it.
        public let firstPersonIndexRange: Range<Int>?
        /// The slot's vertices at rest.
        public let bounds: GLTFBounds
        /// Whether the primitive the slot came from declares morph targets. The
        /// others' vertices hold zero deltas for every target.
        public let hasBlendShapes: Bool

        /// Where the triangles drawn for the camera sit in ``GLTFMeshGeometry/indices``.
        public func indexRange(isFirstPerson: Bool) -> Range<Int> {
            isFirstPerson ? firstPersonIndexRange ?? indexRange : indexRange
        }
    }

    public let positions: [SIMD3<Float>]
    /// Empty when no primitive carries normals.
    public let normals: [SIMD3<Float>]
    /// Empty when no material samples a normal map.
    public let tangents: [SIMD3<Float>]
    public let bitangents: [SIMD3<Float>]
    /// Empty when no primitive carries texture coordinates.
    public let texcoords: [SIMD2<Float>]
    /// Every slot's triangles in slot order, followed by the first-person cuts.
    public let indices: [UInt32]
    public let slots: [Slot]
    /// Four joints per vertex in the skeleton's joint order, empty for an unskinned mesh.
    public let jointIndices: [SIMD4<UInt32>]
    /// The four weights of ``jointIndices``, renormalized to sum to one.
    public let jointWeights: [SIMD4<Float>]
    public let blendShapeTargetCount: Int
    /// The whole mesh at rest.
    public let bounds: GLTFBounds
    /// The POSITION deltas of every target over every vertex. Nil for a mesh without targets.
    public let blendShapeOffsetBuffer: GLTFBlendShapeOffsetBuffer?

    public var vertexCount: Int { positions.count }
    public var isSkinned: Bool { !jointIndices.isEmpty }
    public var hasBlendShapes: Bool { blendShapeTargetCount > 0 }

    /// The POSITION deltas of one morph target, one per vertex. Zero for the vertices
    /// of a primitive that declares no targets, and empty for a target the mesh has not.
    public func blendShapeOffsets(forTarget target: Int) -> [SIMD3<Float>] {
        blendShapeOffsetBuffer?.offsets(forTarget: target) ?? []
    }

    /// The triangles a slot draws, as `indices` into ``positions``.
    public func triangleIndices(ofSlot slot: Int, isFirstPerson: Bool = false) -> ArraySlice<UInt32> {
        indices[slots[slot].indexRange(isFirstPerson: isFirstPerson)]
    }
}

extension GLTFMeshGeometry {
    /// Lays `primitives` out as one vertex array and one index array, one slot each.
    /// A primitive missing an attribute another carries gets zeros for it, so every
    /// vertex reads the same layout.
    package init(primitives: [GLTFPreparedPrimitive],
                 isSkinned: Bool,
                 blendShapeTargetCount: Int) {
        let vertexCount = primitives.reduce(0) { $0 + $1.geometry.positions.count }
        let wholeIndexCount = primitives.reduce(0) { $0 + $1.geometry.indices.count }
        let hasNormals = primitives.contains { !$0.geometry.normals.isEmpty }
        let hasTangents = primitives.contains { !$0.geometry.tangents.isEmpty }
        let hasTexcoords = primitives.contains { !$0.geometry.texcoords.isEmpty }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var tangents: [SIMD3<Float>] = []
        var bitangents: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var jointIndices: [SIMD4<UInt32>] = []
        var jointWeights: [SIMD4<Float>] = []
        var indices: [UInt32] = []
        var cuts: [UInt32] = []
        var slots: [Slot] = []
        positions.reserveCapacity(vertexCount)
        if hasNormals { normals.reserveCapacity(vertexCount) }
        if hasTangents {
            tangents.reserveCapacity(vertexCount)
            bitangents.reserveCapacity(vertexCount)
        }
        if hasTexcoords { texcoords.reserveCapacity(vertexCount) }
        if isSkinned {
            jointIndices.reserveCapacity(vertexCount)
            jointWeights.reserveCapacity(vertexCount)
        }
        indices.reserveCapacity(wholeIndexCount)
        slots.reserveCapacity(primitives.count)

        func append<Element>(_ values: [Element], paddedTo count: Int, with filler: Element,
                             to array: inout [Element]) {
            if values.isEmpty {
                array.append(contentsOf: repeatElement(filler, count: count))
            } else {
                array.append(contentsOf: values)
            }
        }

        // The cuts go after every slot's whole triangles, so a slot's range is
        // contiguous whichever way it is drawn.
        var cutStart = wholeIndexCount
        for primitive in primitives {
            let geometry = primitive.geometry
            let base = positions.count
            let count = geometry.positions.count
            positions.append(contentsOf: geometry.positions)
            if hasNormals { append(geometry.normals, paddedTo: count, with: .zero, to: &normals) }
            if hasTangents {
                append(geometry.tangents, paddedTo: count, with: .zero, to: &tangents)
                append(geometry.bitangents, paddedTo: count, with: .zero, to: &bitangents)
            }
            if hasTexcoords { append(geometry.texcoords, paddedTo: count, with: .zero, to: &texcoords) }
            if isSkinned {
                append(primitive.jointInfluences?.joints ?? [], paddedTo: count, with: .zero, to: &jointIndices)
                append(primitive.jointInfluences?.weights ?? [], paddedTo: count, with: .zero, to: &jointWeights)
            }
            let indexStart = indices.count
            for index in geometry.indices {
                indices.append(index + UInt32(base))
            }
            var firstPersonIndexRange: Range<Int>?
            switch primitive.firstPersonMask {
            case .whole:
                break
            case .nothing:
                firstPersonIndexRange = cutStart..<cutStart
            case .triangles(let cutIndices):
                for index in cutIndices {
                    cuts.append(index + UInt32(base))
                }
                firstPersonIndexRange = cutStart..<cutStart + cutIndices.count
                cutStart += cutIndices.count
            }
            slots.append(Slot(vertexRange: base..<base + count,
                              indexRange: indexStart..<indices.count,
                              firstPersonIndexRange: firstPersonIndexRange,
                              bounds: Self.bounds(of: positions[base..<base + count]),
                              hasBlendShapes: !geometry.blendShapeOffsets.isEmpty))
        }
        indices.append(contentsOf: cuts)

        var blendShapeOffsetBuffer: GLTFBlendShapeOffsetBuffer?
        if blendShapeTargetCount > 0, vertexCount > 0 {
            // A primitive without targets leaves its vertices' deltas at the zero the
            // buffer starts with.
            let buffer = GLTFBlendShapeOffsetBuffer(targetCount: blendShapeTargetCount, vertexCount: vertexCount)
            for (primitive, slot) in zip(primitives, slots) {
                for (target, offsets) in primitive.geometry.blendShapeOffsets.enumerated() where target < blendShapeTargetCount {
                    buffer.write(offsets, target: target, firstVertex: slot.vertexRange.lowerBound)
                }
            }
            blendShapeOffsetBuffer = buffer
        }

        self.positions = positions
        self.normals = normals
        self.tangents = tangents
        self.bitangents = bitangents
        self.texcoords = texcoords
        self.indices = indices
        self.slots = slots
        self.jointIndices = jointIndices
        self.jointWeights = jointWeights
        self.blendShapeTargetCount = blendShapeTargetCount
        self.bounds = slots.dropFirst().reduce(slots.first?.bounds ?? GLTFBounds(min: .zero, max: .zero)) {
            $0.union($1.bounds)
        }
        self.blendShapeOffsetBuffer = blendShapeOffsetBuffer
    }

    private static func bounds(of positions: ArraySlice<SIMD3<Float>>) -> GLTFBounds {
        guard var minimum = positions.first else { return GLTFBounds(min: .zero, max: .zero) }
        var maximum = minimum
        for position in positions {
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        return GLTFBounds(min: minimum, max: maximum)
    }
}

/// An axis-aligned box.
public struct GLTFBounds: Equatable, Sendable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public var center: SIMD3<Float> { (min + max) / 2 }
    public var extents: SIMD3<Float> { max - min }
    /// The radius of the sphere around ``center`` that holds the whole box.
    public var boundingRadius: Float { simd_length(extents) / 2 }

    public func union(_ other: GLTFBounds) -> GLTFBounds {
        GLTFBounds(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }
}

/// The POSITION deltas of every morph target over every vertex of a mesh: target-major,
/// three packed floats per vertex.
///
/// Kept once, in memory mapped a whole number of pages long, so that a renderer can hand
/// it to the GPU without copying it (Metal's `makeBuffer(bytesNoCopy:)`) as long as it holds
/// on to this object. Metal takes such memory only from the virtual memory system: the iOS
/// simulator crashes on a `malloc` block even when it is page-aligned.
public final class GLTFBlendShapeOffsetBuffer: @unchecked Sendable {
    public let targetCount: Int
    public let vertexCount: Int
    /// Where the deltas start. Valid while this object lives.
    public let baseAddress: UnsafeRawPointer
    /// The bytes the deltas take up.
    public var byteCount: Int { targetCount * vertexCount * 12 }
    /// The bytes allocated, a whole number of pages.
    public let allocatedByteCount: Int

    init(targetCount: Int, vertexCount: Int) {
        self.targetCount = targetCount
        self.vertexCount = vertexCount
        let pageSize = Int(getpagesize())
        let byteCount = targetCount * vertexCount * 12
        allocatedByteCount = Swift.max(pageSize, (byteCount + pageSize - 1) / pageSize * pageSize)
        // An anonymous mapping starts zeroed, the delta of a primitive declaring no targets.
        // Darwin imports `mmap` as returning an optional and Android does not.
        let memory: UnsafeMutableRawPointer? = mmap(nil, allocatedByteCount, PROT_READ | PROT_WRITE,
                                                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
        guard let memory, memory != UnsafeMutableRawPointer(bitPattern: -1) else {
            fatalError("could not allocate the blend shape offsets of a mesh")
        }
        baseAddress = UnsafeRawPointer(memory)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: baseAddress), allocatedByteCount)
    }

    /// One target's deltas, one per vertex. Empty for a target the mesh has not.
    public func offsets(forTarget target: Int) -> [SIMD3<Float>] {
        guard (0..<targetCount).contains(target) else { return [] }
        let floats = baseAddress.advanced(by: target * vertexCount * 12).assumingMemoryBound(to: Float.self)
        return (0..<vertexCount).map { SIMD3(floats[$0 * 3], floats[$0 * 3 + 1], floats[$0 * 3 + 2]) }
    }

    fileprivate func write(_ offsets: [SIMD3<Float>], target: Int, firstVertex: Int) {
        let floats = UnsafeMutableRawPointer(mutating: baseAddress)
            .advanced(by: (target * vertexCount + firstVertex) * 12)
            .assumingMemoryBound(to: Float.self)
        for (index, offset) in offsets.enumerated() {
            floats[index * 3] = offset.x
            floats[index * 3 + 1] = offset.y
            floats[index * 3 + 2] = offset.z
        }
    }
}
