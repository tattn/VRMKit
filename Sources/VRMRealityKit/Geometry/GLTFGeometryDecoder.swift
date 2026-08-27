#if canImport(RealityKit)
import Foundation
import simd
import VRMKit

/// A limitation a decode ran into, logged once per key by the loader.
struct GLTFGeometryWarning: Sendable {
    let key: String
    let message: String
}

/// One primitive's vertex data, conditioned for the renderer: triangulated,
/// expanded and flat shaded where glTF gave no normals, and carrying a tangent
/// basis where a normal map samples one.
///
/// Plain values, so a whole model's primitives decode in parallel.
struct GLTFPrimitiveGeometry: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var tangents: [SIMD3<Float>] = []
    var bitangents: [SIMD3<Float>] = []
    var texcoords: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    /// POSITION deltas per morph target. RealityKit blend shapes have no
    /// NORMAL / TANGENT channel, so nothing else is read.
    var blendShapeOffsets: [[SIMD3<Float>]] = []
    /// Empty for an unskinned primitive.
    var joints: [SIMD4<UInt32>] = []
    var weights: [SIMD4<Float>] = []
    var jointIndexRemap: [Int] = []
    var warnings: [GLTFGeometryWarning] = []

    var isSkinned: Bool { !joints.isEmpty }
}

/// Turns a glTF primitive into the vertex buffers a renderer draws.
///
/// Nothing here touches RealityKit or the scene graph, which is what lets a
/// load decode every primitive of a model at once.
struct GLTFGeometryDecoder: Sendable {
    let accessors: PackedAccessorCache
    /// Which UV set each material's textures are read from, resolved before the
    /// decode so that a primitive needs no material state of its own.
    let texcoordSelections: [Int: TexcoordSelection]
    /// The materials that sample a normal map, which is what decides whether a
    /// primitive needs a tangent basis generating.
    let materialsSamplingNormalTexture: Set<Int>
    /// Each skin's glTF joint index to skeleton joint index mapping.
    let jointIndexRemaps: [Int: [Int]]

    /// Nil for a primitive this renderer draws nothing of.
    func decode(_ primitive: GLTF.Mesh.Primitive, skinIndex: Int?) throws -> GLTFPrimitiveGeometry? {
        guard Self.drawsTriangles(primitive.mode) else { return nil }

        var geometry = GLTFPrimitiveGeometry()
        let attributes = primitive.attributes
        guard let positionIndex = attributes[.POSITION] else {
            throw VRMError._dataInconsistent("POSITION attribute is missing")
        }
        let positions = try vector3s(positionIndex)

        // glTF requires every vertex attribute to hold as many elements as POSITION.
        func vertexAttribute<Element>(_ key: GLTF.Mesh.Primitive.AttributeKey,
                                      _ read: (Int) throws -> [Element]) throws -> [Element]? {
            guard let accessorIndex = attributes[key] else { return nil }
            let values = try read(accessorIndex)
            guard values.count == positions.count else {
                throw VRMError._dataInconsistent(
                    "\(key) has \(values.count) elements but POSITION has \(positions.count)"
                )
            }
            return values
        }

        if attributes[.COLOR_0] != nil {
            geometry.warnings.append(GLTFGeometryWarning(
                key: "COLOR_0",
                message: "COLOR_0 vertex colors are not applied; the mesh parts this renderer builds carry no "
                    + "vertex-color channel. The primitive renders without them."
            ))
        }

        let normals = try vertexAttribute(.NORMAL, vector3s)
        // A primitive without NORMAL is flat shaded, and glTF has its TANGENTs
        // ignored along with it: they were authored for the normals it omits.
        let rawTangents = normals == nil ? nil : try vertexAttribute(.TANGENT, vector4s)
        let texcoordKey = texcoordAttributeKey(forMaterialIndex: primitive.material,
                                               attributes: attributes,
                                               warnings: &geometry.warnings)
        let texcoords = try vertexAttribute(texcoordKey, vector2s)

        // glTF requires every primitive of a skinned mesh to carry both skinning
        // attributes, so a missing one is a malformed asset, not an unskinned mesh.
        if let skinIndex {
            guard let joints = try vertexAttribute(.JOINTS_0, jointIndices),
                  let weights = try vertexAttribute(.WEIGHTS_0, jointWeights) else {
                throw VRMError._dataInconsistent(
                    "a primitive of a mesh skinned by skin \(skinIndex) has no JOINTS_0 / WEIGHTS_0 attribute"
                )
            }
            geometry.joints = joints
            geometry.weights = weights
            geometry.jointIndexRemap = jointIndexRemaps[skinIndex] ?? []

            // glTF numbers further sets for a vertex weighted by more than the
            // four influences this renderer draws, which glTF allows.
            if attributes[.joints(1)] != nil || attributes[.weights(1)] != nil {
                geometry.warnings.append(GLTFGeometryWarning(
                    key: "JOINTS_1",
                    message: "JOINTS_1 / WEIGHTS_1 are not applied; this renderer skins a vertex through the "
                        + "four influences of JOINTS_0 / WEIGHTS_0. The primitive poses without the rest."
                ))
            }
        }

        var targetOffsets: [[SIMD3<Float>]] = []
        if let targets = primitive.targets, !targets.isEmpty {
            targetOffsets.reserveCapacity(targets.count)
            for target in targets {
                if let positionAccessor = target[.POSITION] {
                    let offsets = try vector3s(positionAccessor)
                    guard offsets.count == positions.count else {
                        throw VRMError._dataInconsistent(
                            "blend shape target count \(offsets.count) does not match vertex count \(positions.count)"
                        )
                    }
                    targetOffsets.append(offsets)
                } else {
                    targetOffsets.append(Array(repeating: .zero, count: positions.count))
                }
            }
        }

        var indexData: [UInt32]
        if let indicesAccessor = primitive.indices {
            indexData = try indexValues(indicesAccessor)
        } else {
            indexData = (0..<positions.count).map { UInt32($0) }
        }
        indexData = try Self.triangulatedIndices(for: primitive.mode, indices: indexData)
        if let maxIndex = indexData.max(), Int(maxIndex) >= positions.count {
            throw VRMError._dataInconsistent(
                "triangle index \(maxIndex) is out of range for \(positions.count) vertices"
            )
        }

        geometry.positions = positions
        geometry.texcoords = texcoords ?? []
        if normals == nil {
            // Flat shading needs a normal per triangle corner, so every attribute
            // is expanded along the triangle list and the index buffer with it.
            let corners = indexData
            func expanded<Element>(_ values: [Element]) -> [Element] {
                values.isEmpty ? values : corners.map { values[Int($0)] }
            }
            geometry.positions = expanded(geometry.positions)
            geometry.texcoords = expanded(geometry.texcoords)
            geometry.joints = expanded(geometry.joints)
            geometry.weights = expanded(geometry.weights)
            targetOffsets = targetOffsets.map(expanded)
            indexData = Array(0..<UInt32(geometry.positions.count))
        }
        geometry.indices = indexData
        geometry.blendShapeOffsets = targetOffsets
        geometry.normals = normals ?? Self.flatNormals(positions: geometry.positions)

        let frame = tangentFrame(rawTangents: rawTangents,
                                 positions: geometry.positions,
                                 normals: geometry.normals,
                                 texcoords: geometry.texcoords,
                                 indices: geometry.indices,
                                 materialIndex: primitive.material)
        geometry.tangents = frame.tangents
        geometry.bitangents = frame.bitangents
        return geometry
    }

    /// Which UV set a material's textures sample, and whether they agree.
    struct TexcoordSelection: Sendable {
        let selected: Int
        let isMixed: Bool
    }

    /// RealityKit meshes carry one UV channel, so a material sampling several
    /// sets renders through whichever of them this primitive can supply.
    private func texcoordAttributeKey(
        forMaterialIndex materialIndex: Int?,
        attributes: [GLTF.Mesh.Primitive.AttributeKey: Int],
        warnings: inout [GLTFGeometryWarning]
    ) -> GLTF.Mesh.Primitive.AttributeKey {
        guard let materialIndex, let resolved = texcoordSelections[materialIndex] else { return .TEXCOORD_0 }
        let selected = resolved.selected
        guard selected != 0 else { return .TEXCOORD_0 }
        let isMixed = resolved.isMixed
        let isAvailable = selected == 1 && attributes[.TEXCOORD_1] != nil
        if isMixed || !isAvailable {
            warnings.append(GLTFGeometryWarning(key: "texCoord-\(materialIndex)", message: """
                Material \(materialIndex) samples UV set \(selected)\(isMixed ? " among others" : ""); \
                RealityKit meshes carry one UV channel, so \
                \(isAvailable ? "that set is used for every texture" : "TEXCOORD_0 is used instead").
                """))
        }
        return isAvailable ? .TEXCOORD_1 : .TEXCOORD_0
    }

    // MARK: - Attributes

    /// UVs arrive V-flipped: glTF's origin is top-left, RealityKit's is bottom-left.
    private func vector2s(_ accessorIndex: Int) throws -> [SIMD2<Float>] {
        try accessors.floatElements(at: accessorIndex, type: .VEC2) {
            SIMD2<Float>($0(0), 1.0 - $0(1))
        }
    }

    private func vector3s(_ accessorIndex: Int) throws -> [SIMD3<Float>] {
        try accessors.floatElements(at: accessorIndex, type: .VEC3) {
            SIMD3<Float>($0(0), $0(1), $0(2))
        }
    }

    private func vector4s(_ accessorIndex: Int) throws -> [SIMD4<Float>] {
        try accessors.floatElements(at: accessorIndex, type: .VEC4) {
            SIMD4<Float>($0(0), $0(1), $0(2), $0(3))
        }
    }

    private func indexValues(_ accessorIndex: Int) throws -> [UInt32] {
        try accessors.accessor(at: accessorIndex).unsignedElements(.SCALAR) { $0(0) }
    }

    private func jointIndices(_ accessorIndex: Int) throws -> [SIMD4<UInt32>] {
        try accessors.accessor(at: accessorIndex).jointIndices()
    }

    private func jointWeights(_ accessorIndex: Int) throws -> [SIMD4<Float>] {
        try accessors.accessor(at: accessorIndex).jointWeights()
    }

    // MARK: - Topology

    static func drawsTriangles(_ mode: GLTF.Mesh.Primitive.Mode) -> Bool {
        switch mode {
        case .TRIANGLES, .TRIANGLE_STRIP, .TRIANGLE_FAN: true
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP: false
        }
    }

    static func triangulatedIndices(for mode: GLTF.Mesh.Primitive.Mode,
                                    indices: [UInt32]) throws -> [UInt32] {
        switch mode {
        case .TRIANGLES:
            guard !indices.isEmpty, indices.count.isMultiple(of: 3) else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLES primitive needs a non-zero multiple of 3 indices, but has \(indices.count)"
                )
            }
            return indices
        case .TRIANGLE_STRIP:
            guard indices.count >= 3 else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLE_STRIP primitive needs at least 3 indices, but has \(indices.count)"
                )
            }
            var result: [UInt32] = []
            result.reserveCapacity((indices.count - 2) * 3)
            for i in 0..<(indices.count - 2) {
                let i0 = indices[i]
                let i1 = indices[i + 1]
                let i2 = indices[i + 2]
                if i.isMultiple(of: 2) {
                    result.append(contentsOf: [i0, i1, i2])
                } else {
                    result.append(contentsOf: [i1, i0, i2])
                }
            }
            return result
        case .TRIANGLE_FAN:
            guard indices.count >= 3 else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLE_FAN primitive needs at least 3 indices, but has \(indices.count)"
                )
            }
            let base = indices[0]
            var result: [UInt32] = []
            result.reserveCapacity((indices.count - 2) * 3)
            for i in 1..<(indices.count - 1) {
                result.append(contentsOf: [base, indices[i], indices[i + 1]])
            }
            return result
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP:
            // Filtered out by drawsTriangles() before the indices are read.
            throw VRMError._notSupported("\(mode) primitives have no triangles")
        }
    }

    /// The flat normals glTF asks for when a primitive ships no NORMAL: one face
    /// normal shared by the triangle's three corners.
    ///
    /// - Precondition: the positions are expanded per triangle corner, so each
    ///   triangle owns the vertices it writes.
    static func flatNormals(positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for base in stride(from: 0, to: positions.count - positions.count % 3, by: 3) {
            let faceNormal = simd_cross(positions[base + 1] - positions[base],
                                        positions[base + 2] - positions[base])
            // A degenerate triangle keeps a zero normal rather than a NaN one.
            guard simd_length_squared(faceNormal) > 1e-24 else { continue }
            let normal = simd_normalize(faceNormal)
            normals[base] = normal
            normals[base + 1] = normal
            normals[base + 2] = normal
        }
        return normals
    }

    // MARK: - Tangents

    /// A complete tangent basis. RealityKit derives neither buffer from the other,
    /// so both are filled together or left empty together.
    private struct TangentFrame {
        static let empty = TangentFrame(tangents: [], bitangents: [])

        let tangents: [SIMD3<Float>]
        let bitangents: [SIMD3<Float>]
    }

    /// The tangent basis a normal map needs: glTF `TANGENT` when the primitive has
    /// one, otherwise derived from the UVs. Skipped when no normal map samples it.
    private func tangentFrame(rawTangents: [SIMD4<Float>]?,
                              positions: [SIMD3<Float>],
                              normals: [SIMD3<Float>],
                              texcoords: [SIMD2<Float>],
                              indices: [UInt32],
                              materialIndex: Int?) -> TangentFrame {
        // Nothing samples the basis unless the material has a normal map, so
        // even authored TANGENTs are left unexpanded without one.
        guard let materialIndex,
              materialsSamplingNormalTexture.contains(materialIndex) else {
            return .empty
        }
        if let rawTangents {
            // glTF stores handedness in w.
            var tangents = [SIMD3<Float>](repeating: .zero, count: positions.count)
            var bitangents = tangents
            for i in 0..<positions.count {
                let raw = rawTangents[i]
                let tangent = SIMD3<Float>(raw.x, raw.y, raw.z)
                tangents[i] = tangent
                bitangents[i] = simd_cross(normals[i], tangent) * (raw.w < 0 ? -1 : 1)
            }
            return TangentFrame(tangents: tangents, bitangents: bitangents)
        }
        guard texcoords.count == positions.count else {
            return .empty
        }
        return Self.generatedTangentFrame(positions: positions,
                                          normals: normals,
                                          texcoords: texcoords,
                                          indices: indices)
    }

    /// Per-triangle UV gradients accumulated per vertex, then orthonormalized
    /// against the normal. The spec only recommends MikkTSpace, so a mesh whose
    /// normal map was baked against it can differ slightly along UV seams.
    private static func generatedTangentFrame(positions: [SIMD3<Float>],
                                              normals: [SIMD3<Float>],
                                              texcoords: [SIMD2<Float>],
                                              indices: [UInt32]) -> TangentFrame {
        var tangentSums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var bitangentSums = tangentSums
        let triangleCount = indices.count / 3
        for i in 0..<triangleCount {
            let base = i * 3
            let i0 = Int(indices[base])
            let i1 = Int(indices[base + 1])
            let i2 = Int(indices[base + 2])

            let edge1 = positions[i1] - positions[i0]
            let edge2 = positions[i2] - positions[i0]
            // `texcoords` point v up while the normal map works in glTF UV space,
            // so the v gradients are negated back into it.
            let deltaUV1 = gltfUVDelta(texcoords[i1] - texcoords[i0])
            let deltaUV2 = gltfUVDelta(texcoords[i2] - texcoords[i0])

            // A degenerate UV triangle carries no direction.
            let determinant = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y
            guard abs(determinant) > 1e-12 else { continue }
            let scale = 1 / determinant
            let tangent = (edge1 * deltaUV2.y - edge2 * deltaUV1.y) * scale
            let bitangent = (edge2 * deltaUV1.x - edge1 * deltaUV2.x) * scale
            tangentSums[i0] += tangent
            tangentSums[i1] += tangent
            tangentSums[i2] += tangent
            bitangentSums[i0] += bitangent
            bitangentSums[i1] += bitangent
            bitangentSums[i2] += bitangent
        }

        var tangents = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var bitangents = tangents
        for i in 0..<positions.count {
            let normal = normals[i]
            let tangent = orthonormalizedTangent(tangentSums[i], normal: normal)
            tangents[i] = tangent
            // Mirrored UV islands need the flipped bitangent.
            let bitangent = simd_cross(normal, tangent)
            bitangents[i] = simd_dot(bitangent, bitangentSums[i]) < 0 ? -bitangent : bitangent
        }
        return TangentFrame(tangents: tangents, bitangents: bitangents)
    }

    /// A UV difference converted from the mesh's v-up coordinates into glTF UV space.
    private static func gltfUVDelta(_ delta: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(delta.x, -delta.y)
    }

    /// Gram-Schmidt against the normal, falling back to any perpendicular axis.
    private static func orthonormalizedTangent(_ tangent: SIMD3<Float>,
                                               normal: SIMD3<Float>) -> SIMD3<Float> {
        // A degenerate triangle leaves the zero normal `flatNormals()` writes, and
        // nothing is perpendicular to it.
        guard simd_length_squared(normal) > 1e-12 else { return .zero }
        let projected = tangent - normal * simd_dot(normal, tangent)
        if simd_length_squared(projected) > 1e-12 {
            return simd_normalize(projected)
        }
        let axis = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(normal, axis))
    }
}
#endif
