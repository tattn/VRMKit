#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat
import VRMKit

/// A limitation a decode ran into, for a renderer to report once per key.
package struct GLTFGeometryWarning: Sendable {
    package let key: String
    package let message: String
}

/// One primitive's vertex data, conditioned for the renderer: triangulated,
/// expanded and flat shaded where glTF gave no normals, and carrying a tangent
/// basis where a normal map samples one.
///
/// Plain values, so a whole model's primitives decode in parallel.
package struct GLTFPrimitiveGeometry: Sendable {
    package var positions: [SIMD3<Float>] = []
    package var normals: [SIMD3<Float>] = []
    package var tangents: [SIMD3<Float>] = []
    package var bitangents: [SIMD3<Float>] = []
    package var texcoords: [SIMD2<Float>] = []
    package var indices: [UInt32] = []
    package var blendShapes = GLTFPrimitiveBlendShapes()
    /// Empty for an unskinned primitive.
    package var joints: [SIMD4<UInt32>] = []
    package var weights: [SIMD4<Float>] = []
    package var jointIndexRemap: [Int] = []
    package var warnings: [GLTFGeometryWarning] = []

    package var isSkinned: Bool { !joints.isEmpty }
}

/// A primitive's morph targets, left where the document stores them until a mesh lays out
/// the buffer their deltas go to, so each delta is read once, straight into it.
package struct GLTFPrimitiveBlendShapes: Sendable {
    /// The POSITION deltas of each target, nil for a target that moves nothing. The
    /// deformation kernel morphs positions only, so nothing else is read.
    package var targets: [AccessorReader?]
    /// The element of a target each vertex of the primitive reads, nil when vertex `i`
    /// reads element `i`.
    package var sources: [UInt32]?

    package init(targets: [AccessorReader?] = [], sources: [UInt32]? = nil) {
        self.targets = targets
        self.sources = sources
    }

    package var isEmpty: Bool { targets.isEmpty }
}

/// Turns a glTF primitive into the vertex buffers a renderer draws.
///
/// Nothing here touches a renderer, which is what lets a load decode every primitive
/// of a model at once.
package struct GLTFGeometryDecoder: Sendable {
    package let accessors: AccessorReaderCache
    /// Which UV set each material's textures are read from, resolved before the
    /// decode so that a primitive needs no material state of its own.
    package let texcoordSelections: [Int: TexcoordSelection]
    /// The materials that sample a normal map, which is what decides whether a
    /// primitive needs a tangent basis generating.
    package let materialsSamplingNormalTexture: Set<Int>
    /// Each skin's glTF joint index to skeleton joint index mapping.
    package let jointIndexRemaps: [Int: [Int]]

    package init(accessors: AccessorReaderCache,
                 texcoordSelections: [Int: TexcoordSelection],
                 materialsSamplingNormalTexture: Set<Int>,
                 jointIndexRemaps: [Int: [Int]]) {
        self.accessors = accessors
        self.texcoordSelections = texcoordSelections
        self.materialsSamplingNormalTexture = materialsSamplingNormalTexture
        self.jointIndexRemaps = jointIndexRemaps
    }

    /// Nil for a primitive this renderer draws nothing of.
    ///
    /// Every accessor is checked before any vertex is read, and the triangles are read first,
    /// so that only the vertices they draw are read out of each attribute.
    package func decode(_ primitive: GLTF.Mesh.Primitive, skinIndex: Int?) throws -> GLTFPrimitiveGeometry? {
        guard Self.drawsTriangles(primitive.mode) else { return nil }

        var geometry = GLTFPrimitiveGeometry()
        let attributes = primitive.attributes
        guard let positionIndex = attributes[.POSITION] else {
            throw VRMError._dataInconsistent("POSITION attribute is missing")
        }
        let positions = try accessors.accessor(at: positionIndex)
        try positions.validate(.VEC3)
        let vertexCount = positions.count

        // glTF requires every vertex attribute to hold as many elements as POSITION.
        func vertexAttribute(_ key: GLTF.Mesh.Primitive.AttributeKey,
                             _ validate: (AccessorReader) throws -> Void) throws -> AccessorReader? {
            guard let accessorIndex = attributes[key] else { return nil }
            let reader = try accessors.accessor(at: accessorIndex)
            try validate(reader)
            guard reader.count == vertexCount else {
                throw VRMError._dataInconsistent(
                    "\(key) has \(reader.count) elements but POSITION has \(vertexCount)"
                )
            }
            return reader
        }

        if attributes[.COLOR_0] != nil {
            geometry.warnings.append(GLTFGeometryWarning(
                key: "COLOR_0",
                message: "COLOR_0 vertex colors are not applied; the mesh parts this renderer builds carry no "
                    + "vertex-color channel. The primitive renders without them."
            ))
        }

        let normals = try vertexAttribute(.NORMAL) { try $0.validate(.VEC3) }
        // A primitive without NORMAL is flat shaded, and glTF has its TANGENTs
        // ignored along with it: they were authored for the normals it omits.
        let rawTangents = normals == nil ? nil : try vertexAttribute(.TANGENT) { try $0.validate(.VEC4) }
        let texcoordKey = texcoordAttributeKey(forMaterialIndex: primitive.material,
                                               attributes: attributes,
                                               warnings: &geometry.warnings)
        let texcoords = try vertexAttribute(texcoordKey) { try $0.validate(.VEC2) }

        // glTF requires every primitive of a skinned mesh to carry both skinning
        // attributes, so a missing one is a malformed asset, not an unskinned mesh.
        var skinning: (joints: AccessorReader, weights: AccessorReader)?
        if let skinIndex {
            guard let joints = try vertexAttribute(.JOINTS_0, { try $0.validateJointIndices() }),
                  let weights = try vertexAttribute(.WEIGHTS_0, { try $0.validateJointWeights() }) else {
                throw VRMError._dataInconsistent(
                    "a primitive of a mesh skinned by skin \(skinIndex) has no JOINTS_0 / WEIGHTS_0 attribute"
                )
            }
            skinning = (joints, weights)
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

        var targets: [AccessorReader?] = []
        if let primitiveTargets = primitive.targets, !primitiveTargets.isEmpty {
            targets.reserveCapacity(primitiveTargets.count)
            for target in primitiveTargets {
                guard let positionAccessor = target[.POSITION] else {
                    targets.append(nil)
                    continue
                }
                let deltas = try accessors.accessor(at: positionAccessor)
                try deltas.validate(.VEC3)
                guard deltas.count == vertexCount else {
                    throw VRMError._dataInconsistent(
                        "blend shape target count \(deltas.count) does not match vertex count \(vertexCount)"
                    )
                }
                targets.append(deltas)
            }
        }

        var indices: [UInt32]
        if let indicesAccessor = primitive.indices {
            indices = try indexValues(indicesAccessor)
        } else {
            indices = (0..<vertexCount).map { UInt32($0) }
        }
        indices = try Self.triangulatedIndices(for: primitive.mode, indices: indices)
        if let maxIndex = indices.max(), Int(maxIndex) >= vertexCount {
            throw VRMError._dataInconsistent(
                "triangle index \(maxIndex) is out of range for \(vertexCount) vertices"
            )
        }

        let sources: [UInt32]?
        if normals == nil {
            // Flat shading needs a normal per triangle corner, so every attribute is read
            // along the triangle list, which draws each corner once.
            sources = indices
            indices = Array(0..<UInt32(indices.count))
        } else {
            sources = Self.drawnVertices(renumbering: &indices, vertexCount: vertexCount)
        }

        geometry.indices = indices
        geometry.positions = try Self.vector3s(positions, at: sources)
        geometry.normals = try normals.map { try Self.vector3s($0, at: sources) }
            ?? Self.flatNormals(positions: geometry.positions)
        geometry.texcoords = try texcoords.map { try Self.vector2s($0, at: sources) } ?? []
        if let skinning {
            geometry.joints = try skinning.joints.jointIndices(at: sources)
            geometry.weights = try skinning.weights.jointWeights(at: sources)
        }
        geometry.blendShapes = GLTFPrimitiveBlendShapes(targets: targets, sources: sources)

        // Nothing samples the basis unless the material has a normal map, so even
        // authored TANGENTs are left unread without one.
        if let material = primitive.material, materialsSamplingNormalTexture.contains(material) {
            let frame = Self.tangentFrame(rawTangents: try rawTangents.map { try Self.vector4s($0, at: sources) },
                                          positions: geometry.positions,
                                          normals: geometry.normals,
                                          texcoords: geometry.texcoords,
                                          indices: geometry.indices)
            geometry.tangents = frame.tangents
            geometry.bitangents = frame.bitangents
        }
        return geometry
    }

    /// The vertices `indices` draw, in the order they are first drawn, with `indices`
    /// renumbered to them. Nil when they draw all `vertexCount`, which then keep their order.
    ///
    /// Only these are read: the deformation kernel skins and morphs every vertex in the
    /// buffer, drawn or not, and orphans are common. A VRM 0.x export shares one vertex
    /// buffer across the primitives of a mesh, each drawing its own slice of it: the
    /// `AliciaSolid` fixture holds 80,169 vertices that way for 21,995 drawn. Merged or baked
    /// exports also leave hidden parts behind as unused vertices.
    ///
    /// - Precondition: every index is below `vertexCount`.
    package static func drawnVertices(renumbering indices: inout [UInt32], vertexCount: Int) -> [UInt32]? {
        var renumbered = [UInt32](repeating: .max, count: vertexCount)
        var drawn: [UInt32] = []
        for index in indices where renumbered[Int(index)] == .max {
            renumbered[Int(index)] = UInt32(drawn.count)
            drawn.append(index)
        }
        guard drawn.count < vertexCount else { return nil }
        for position in indices.indices {
            indices[position] = renumbered[Int(indices[position])]
        }
        return drawn
    }

    /// Which UV set a material's textures sample, and whether they agree.
    package struct TexcoordSelection: Sendable {
        package let selected: Int
        package let isMixed: Bool

        package init(selected: Int, isMixed: Bool) {
            self.selected = selected
            self.isMixed = isMixed
        }
    }

    /// A decoded mesh carries one UV channel, so a material sampling several sets
    /// renders through whichever of them this primitive can supply.
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
                a decoded mesh carries one UV channel, so \
                \(isAvailable ? "that set is used for every texture" : "TEXCOORD_0 is used instead").
                """))
        }
        return isAvailable ? .TEXCOORD_1 : .TEXCOORD_0
    }

    // MARK: - Attributes

    /// UVs arrive V-flipped, with the origin bottom-left as RealityKit reads them rather
    /// than glTF's top-left. The generated tangent basis is derived from these UVs.
    private static func vector2s(_ reader: AccessorReader, at sources: [UInt32]?) throws -> [SIMD2<Float>] {
        try reader.floatElements(.VEC2, at: sources) {
            SIMD2<Float>($0(0), 1.0 - $0(1))
        }
    }

    private static func vector3s(_ reader: AccessorReader, at sources: [UInt32]?) throws -> [SIMD3<Float>] {
        try reader.floatElements(.VEC3, at: sources) {
            SIMD3<Float>($0(0), $0(1), $0(2))
        }
    }

    private static func vector4s(_ reader: AccessorReader, at sources: [UInt32]?) throws -> [SIMD4<Float>] {
        try reader.floatElements(.VEC4, at: sources) {
            SIMD4<Float>($0(0), $0(1), $0(2), $0(3))
        }
    }

    private func indexValues(_ accessorIndex: Int) throws -> [UInt32] {
        try accessors.accessor(at: accessorIndex).unsignedElements(.SCALAR) { $0(0) }
    }

    // MARK: - Topology

    package static func drawsTriangles(_ mode: GLTF.Mesh.Primitive.Mode) -> Bool {
        switch mode {
        case .TRIANGLES, .TRIANGLE_STRIP, .TRIANGLE_FAN: true
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP: false
        }
    }

    package static func triangulatedIndices(for mode: GLTF.Mesh.Primitive.Mode,
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
    package static func flatNormals(positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
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

    /// A complete tangent basis. A renderer is handed both buffers rather than deriving
    /// one from the other, so both are filled together or left empty together.
    private struct TangentFrame {
        static let empty = TangentFrame(tangents: [], bitangents: [])

        let tangents: [SIMD3<Float>]
        let bitangents: [SIMD3<Float>]
    }

    /// The tangent basis a normal map needs: glTF `TANGENT` when the primitive has
    /// one, otherwise derived from the UVs.
    private static func tangentFrame(rawTangents: [SIMD4<Float>]?,
                                     positions: [SIMD3<Float>],
                                     normals: [SIMD3<Float>],
                                     texcoords: [SIMD2<Float>],
                                     indices: [UInt32]) -> TangentFrame {
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
        return generatedTangentFrame(positions: positions,
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
            // A normal map's +Y points up the image, the way v grows in `texcoords`,
            // as UniVRM's Unity-generated tangents have it.
            let deltaUV1 = texcoords[i1] - texcoords[i0]
            let deltaUV2 = texcoords[i2] - texcoords[i0]

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
