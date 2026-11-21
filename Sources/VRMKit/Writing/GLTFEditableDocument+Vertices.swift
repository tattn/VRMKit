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
        let count = try vertexCount(ofPrimitive: primitive, meshAt: mesh)
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

    /// The triangles one primitive draws, three indices into its vertices each. A primitive
    /// with no index accessor draws its vertices in order.
    public func indices(ofPrimitive primitive: Int, meshAt mesh: GLTFMeshIndex) throws -> [UInt32] {
        guard let accessor = try self.primitive(primitive, meshAt: mesh).index("indices") else {
            return try Array(0..<UInt32(vertexCount(ofPrimitive: primitive, meshAt: mesh)))
        }
        let layout = try self.accessor(accessor)
        guard layout.type == .SCALAR, layout.sparse == nil, layout.bufferView != nil else {
            throw VRMError._dataInconsistent("accessor \(accessor) does not hold indices")
        }
        return try packed(layout).unsignedElements(.SCALAR) { $0(0) }
    }

    // MARK: - Morph targets

    /// The names a mesh's morph targets go by, in target order: its `extras.targetNames`,
    /// the convention exporters write them in. Empty for a mesh that names none.
    public func morphTargetNames(meshAt mesh: GLTFMeshIndex) throws -> [String] {
        guard let object = json.object(at: mesh.rawValue, in: .meshes) else {
            throw VRMError._invalidArgument("the document has no mesh \(mesh.rawValue)")
        }
        return object.object("extras")?.strings("targetNames") ?? []
    }

    /// How far each morph target moves the vertices of one primitive at full weight: one
    /// displacement per vertex per target, zero where a target leaves POSITION alone.
    public func morphTargetDisplacements(ofPrimitive primitive: Int,
                                         meshAt mesh: GLTFMeshIndex) throws -> [[SIMD3<Float>]] {
        let object = try self.primitive(primitive, meshAt: mesh)
        let count = try vertexCount(ofPrimitive: primitive, meshAt: mesh)
        return try object.objects("targets").map { target in
            try target.index("POSITION").map(vectors(ofAccessor:)) ?? [SIMD3<Float>](repeating: .zero, count: count)
        }
    }

    /// Drops the morph targets of a mesh, leaving its vertices where they rest: what is left
    /// once the weights wanted have been applied through ``setPositions(_:normals:ofPrimitive:meshAt:)``.
    public mutating func removeMorphTargets(meshAt mesh: GLTFMeshIndex) throws {
        guard json.object(at: mesh.rawValue, in: .meshes) != nil else {
            throw VRMError._invalidArgument("the document has no mesh \(mesh.rawValue)")
        }
        json.updateObject(at: mesh.rawValue, in: .meshes) { meshObject in
            meshObject["weights"] = nil
            meshObject.mapObjects("primitives") { primitive in
                var primitive = primitive
                primitive["targets"] = nil
                return primitive
            }
            guard var extras = meshObject.object("extras") else { return }
            extras["targetNames"] = nil
            meshObject["extras"] = extras.isEmpty ? nil : .object(extras)
        }
    }

    private func primitive(_ primitive: Int, meshAt mesh: GLTFMeshIndex) throws -> JSONObject {
        guard let object = json.object(at: mesh.rawValue, in: .meshes)?.object(at: primitive, in: "primitives") else {
            throw VRMError._invalidArgument("the document has no primitive \(primitive) of mesh \(mesh.rawValue)")
        }
        return object
    }

    private func attributes(ofPrimitive primitive: Int, meshAt mesh: GLTFMeshIndex) throws -> JSONObject {
        guard let attributes = try self.primitive(primitive, meshAt: mesh).object("attributes") else {
            throw VRMError._dataInconsistent("primitive \(primitive) of mesh \(mesh.rawValue) has no attributes")
        }
        return attributes
    }

    /// The count its POSITION accessor declares, so that sizing a result does not
    /// decode every position.
    private func vertexCount(ofPrimitive primitive: Int, meshAt mesh: GLTFMeshIndex) throws -> Int {
        guard let accessor = try attributes(ofPrimitive: primitive, meshAt: mesh).index("POSITION"),
              let count = json.object(at: accessor, in: .accessors)?.int("count"), count >= 0 else {
            throw VRMError._dataInconsistent("primitive \(primitive) of mesh \(mesh.rawValue) has no POSITION")
        }
        return count
    }

    /// The values of a three-component accessor, whatever its component type and stride.
    private func vectors(ofAccessor index: Int) throws -> [SIMD3<Float>] {
        try packed(accessor(index)).floatElements(.VEC3) { SIMD3($0(0), $0(1), $0(2)) }
    }

    /// The accessor's elements read out of the single buffer, as loading reads them.
    private func packed(_ accessor: GLTF.Accessor) throws -> PackedAccessor {
        try PackedAccessor(accessor: accessor) { index in
            let view = try bufferView(index)
            return (try view.data(in: binary), view.byteStride)
        }
    }

    // Decoded one at a time, since ``typed()`` decodes every accessor and buffer view
    // the document holds, and a mesh is read one accessor at a time.

    private func accessor(_ index: Int) throws -> GLTF.Accessor {
        try json.object(at: index, in: .accessors)?.decode(GLTF.Accessor.self)
            ??? ._dataInconsistent("the document has no accessor \(index)")
    }

    private func bufferView(_ index: Int) throws -> GLTF.BufferView {
        try json.object(at: index, in: .bufferViews)?.decode(GLTF.BufferView.self)
            ??? ._dataInconsistent("the document has no buffer view \(index)")
    }
}
