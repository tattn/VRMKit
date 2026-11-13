#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat

extension GLTFEditableDocument {
    /// The positions of the vertices one primitive draws, in its mesh's own space.
    ///
    /// Read as glTF stores them, before any morph target or skin moves them.
    public func positions(ofPrimitive primitive: Int, meshAt mesh: GLTFMeshIndex) throws -> [SIMD3<Float>] {
        guard let accessor = try attributes(ofPrimitive: primitive, meshAt: mesh).index("POSITION") else {
            throw VRMError._dataInconsistent("primitive \(primitive) of mesh \(mesh.rawValue) has no POSITION")
        }
        return try vectors(ofAccessor: accessor)
    }

    /// The normals of the vertices one primitive draws, or nil for a primitive carrying none.
    public func normals(ofPrimitive primitive: Int, meshAt mesh: GLTFMeshIndex) throws -> [SIMD3<Float>]? {
        try attributes(ofPrimitive: primitive, meshAt: mesh).index("NORMAL").map(vectors(ofAccessor:))
    }

    /// Moves the vertices of one primitive, and turns their normals with them when `normals` is given.
    ///
    /// The values are written as accessors of their own, so another primitive drawing
    /// the same vertices keeps the ones it had; ``prune()`` reclaims what nothing reads
    /// any more. Everything else the primitive carries, its morph targets included, is
    /// left as it was, so there has to be one value per vertex it already had.
    public mutating func setPositions(_ positions: [SIMD3<Float>],
                             normals: [SIMD3<Float>]? = nil,
                             ofPrimitive primitive: Int,
                             meshAt mesh: GLTFMeshIndex) throws {
        let attributes = try attributes(ofPrimitive: primitive, meshAt: mesh)
        guard let positionAccessor = attributes.index("POSITION"),
              let count = json.objects(.accessors)[safe: positionAccessor]?.int("count") else {
            throw VRMError._dataInconsistent("primitive \(primitive) of mesh \(mesh.rawValue) has no POSITION")
        }
        guard positions.count == count, normals.map({ $0.count == count }) ?? true else {
            throw VRMError._invalidArgument("primitive \(primitive) of mesh \(mesh.rawValue) draws \(count) vertices")
        }
        guard !positions.isEmpty else { return }

        var minimum = positions[0]
        var maximum = positions[0]
        for position in positions {
            minimum = pointwiseMin(minimum, position)
            maximum = pointwiseMax(maximum, position)
        }
        var payloads = [AccessorPayload(data: Self.packed(positions),
                                        type: .VEC3,
                                        componentType: .float,
                                        count: count,
                                        target: .arrayBuffer,
                                        bounds: ([minimum.x, minimum.y, minimum.z], [maximum.x, maximum.y, maximum.z]))]
        if let normals {
            payloads.append(AccessorPayload(data: Self.packed(normals),
                                            type: .VEC3,
                                            componentType: .float,
                                            count: count,
                                            target: .arrayBuffer))
        }
        let accessors = appendAccessors(payloads)
        json.updateObject(at: mesh.rawValue, in: .meshes) { meshObject in
            meshObject.updateObject(at: primitive, in: "primitives") { primitiveObject in
                primitiveObject.withObject("attributes") { attributes in
                    attributes["POSITION"] = .int(accessors[0])
                    if normals != nil { attributes["NORMAL"] = .int(accessors[1]) }
                }
            }
        }
    }

    private func attributes(ofPrimitive primitive: Int, meshAt mesh: GLTFMeshIndex) throws -> JSONObject {
        guard let attributes = json.objects(.meshes)[safe: mesh.rawValue]?
            .objects("primitives")[safe: primitive]?.object("attributes") else {
            throw VRMError._invalidArgument("the document has no primitive \(primitive) of mesh \(mesh.rawValue)")
        }
        return attributes
    }

    /// The values of a three-component accessor, whatever its component type and stride.
    /// A sparse accessor is refused: its values are not all in the buffer view it names.
    private func vectors(ofAccessor index: Int) throws -> [SIMD3<Float>] {
        let model = try typed()
        guard let accessor = model.accessors[safe: index], accessor.type == .VEC3 else {
            throw VRMError._dataInconsistent("accessor \(index) does not hold three-component vectors")
        }
        guard accessor.sparse == nil, let viewIndex = accessor.bufferView,
              let view = model.bufferViews[safe: viewIndex] else {
            throw VRMError._notSupported("accessor \(index) is sparse or names no buffer view")
        }
        let layout = accessor.components()
        let stride = view.byteStride ?? layout.vectorSize
        let start = view.byteOffset + accessor.byteOffset
        guard accessor.count == 0 || start + (accessor.count - 1) * stride + layout.vectorSize <= binary.count else {
            throw VRMError._dataInconsistent("accessor \(index) reads past the end of the buffer")
        }
        return binary.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return [] }
            return (0..<accessor.count).map { element in
                let offset = start + element * stride
                return SIMD3(accessor.floatComponent(base: base, offset: offset),
                             accessor.floatComponent(base: base, offset: offset + layout.bytesPerComponent),
                             accessor.floatComponent(base: base, offset: offset + 2 * layout.bytesPerComponent))
            }
        }
    }
}
