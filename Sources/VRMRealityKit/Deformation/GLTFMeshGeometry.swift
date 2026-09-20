#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import simd
import VRMKit

/// The vertex data behind one model entity of a loaded glTF, as authored: the rest
/// pose, before any skinning or morphing.
///
/// The mesh is drawn from a `LowLevelMesh` the loader deforms itself, which has no
/// readable contents, so anything that needs to know where a vertex sits reads it
/// here, through ``RealityKit/ModelEntity/gltfMeshGeometry``. Every slot of the
/// merged mesh shares the one vertex array and draws its own range of `indices`.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFMeshGeometry: @unchecked Sendable {
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
        public let bounds: BoundingBox
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
    public let bounds: BoundingBox

    /// The POSITION deltas of every target over every vertex, target-major, packed as
    /// the kernel reads them. Kept once, in the buffer the GPU deforms from.
    let blendShapeOffsetStorage: MTLBuffer?

    public var vertexCount: Int { positions.count }
    public var isSkinned: Bool { !jointIndices.isEmpty }
    public var hasBlendShapes: Bool { blendShapeTargetCount > 0 }

    /// The triangles a slot draws, as `indices` into ``positions``.
    /// The POSITION deltas of one morph target, one per vertex. Zero for the vertices
    /// of a primitive that declares no targets, and empty for a target the mesh has not.
    public func blendShapeOffsets(forTarget target: Int) -> [SIMD3<Float>] {
        guard let blendShapeOffsetStorage, (0..<blendShapeTargetCount).contains(target) else { return [] }
        let floats = blendShapeOffsetStorage.contents()
            .advanced(by: target * vertexCount * 12)
            .assumingMemoryBound(to: Float.self)
        return (0..<vertexCount).map { SIMD3(floats[$0 * 3], floats[$0 * 3 + 1], floats[$0 * 3 + 2]) }
    }

    public func triangleIndices(ofSlot slot: Int, isFirstPerson: Bool = false) -> ArraySlice<UInt32> {
        indices[slots[slot].indexRange(isFirstPerson: isFirstPerson)]
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFMeshGeometry {
    /// Lays `primitives` out as one vertex array and one index array, one slot each.
    /// A primitive missing an attribute another carries gets zeros for it, so every
    /// vertex reads the same layout.
    @MainActor
    init(primitives: [GLTFPreparedPrimitive],
         isSkinned: Bool,
         blendShapeTargetCount: Int,
         context: GLTFDeformationContext) throws {
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

        var blendShapeOffsetStorage: MTLBuffer?
        if blendShapeTargetCount > 0, vertexCount > 0 {
            guard let storage = context.device.makeBuffer(length: blendShapeTargetCount * vertexCount * 12,
                                                          options: .storageModeShared) else {
                throw VRMError._notSupported("could not allocate the blend shape offsets of a mesh")
            }
            // A primitive without targets leaves its vertices' deltas at the zero the
            // buffer starts with.
            memset(storage.contents(), 0, storage.length)
            for (primitive, slot) in zip(primitives, slots) {
                for (target, offsets) in primitive.geometry.blendShapeOffsets.enumerated() where target < blendShapeTargetCount {
                    let destination = storage.contents().advanced(by: (target * vertexCount + slot.vertexRange.lowerBound) * 12)
                    GLTFDeformationContext.pack(offsets, into: destination)
                }
            }
            blendShapeOffsetStorage = storage
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
        self.bounds = slots.dropFirst().reduce(slots.first?.bounds ?? BoundingBox(min: .zero, max: .zero)) {
            $0.union($1.bounds)
        }
        self.blendShapeOffsetStorage = blendShapeOffsetStorage
    }

    private static func bounds(of positions: ArraySlice<SIMD3<Float>>) -> BoundingBox {
        guard var minimum = positions.first else { return BoundingBox(min: .zero, max: .zero) }
        var maximum = minimum
        for position in positions {
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        return BoundingBox(min: minimum, max: maximum)
    }
}
#endif
