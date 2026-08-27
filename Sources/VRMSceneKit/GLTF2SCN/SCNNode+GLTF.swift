import VRMKit
import VRMKitRuntime
import SceneKit
import simd

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNNode {
    convenience init(node: GLTF.Node, at nodeIndex: Int, loader: VRMSceneLoader) throws {
        self.init()
        name = node.name
        camera = try node.camera.map(loader.camera)

        if let mesh = node.mesh {
            let meshNode = try loader.mesh(withMeshIndex: mesh, skinIndex: node.skin, nodeIndex: nodeIndex)
            addChildNode(meshNode)

            if let skinIndex = node.skin {
                let skin = try loader.skin(withSkinIndex: skinIndex)
                let joints = try skin.joints.map(loader.node)
                let ibm = try skin.inverseBindMatrices.map(loader.inverseBindMatrix)
                let skeleton = try skin.skeleton.map(loader.node)
                for primitive in meshNode.childNodes {
                    guard let geometry = primitive.geometry else { continue }
                    primitive.skinner = try loader.skin(primitiveGeometry: geometry,
                                                        bones: joints,
                                                        boneInverseBindTransform: ibm)
                    primitive.skinner?.skeleton = skeleton ?? primitive
                }
            }
        }

        if let matrix = node.matrix {
            transform = try SCNMatrix4(matrix.values)
        } else {
            position = node.translation.createSCNVector3()
            orientation = node.rotation.createSCNVector4()
            scale = node.scale.createSCNVector3()
        }

        for child in node.children ?? [] {
            addChildNode(try loader.node(withNodeIndex: child))
        }
    }

    convenience init(mesh: GLTF.Mesh,
                     at meshIndex: Int,
                     skinIndex: Int?,
                     nodeIndex: Int,
                     loader: VRMSceneLoader) throws {
        self.init()
        name = mesh.name
        // A primitive carrying no morph targets of its own morphs with those of
        // whichever primitive shares its POSITION accessor, through one morpher
        // between them rather than a copy each.
        let sharedTargets = mesh.morphTargetsByPositionAccessor()
        var morphers: [Int: SCNMorpher] = [:]
        var cuts: [(SCNNode, FirstPersonPrimitiveMask)] = []

        for primitive in mesh.primitives {
            let node = SCNNode()
            var attributes = try loader.attributes(primitive.attributes)
            let vertex = try attributes.first { $0.semantic == .vertex }
                ??? ._dataInconsistent("a mesh primitive has no POSITION attribute")
            let hasNormal = attributes.contains { $0.semantic == .normal }
            // Every attribute describes the same vertices, so a shorter one
            // would be read past its end.
            if let short = attributes.first(where: { $0.vectorCount < vertex.vectorCount }) {
                throw VRMError._dataInconsistent(
                    "a \(short.semantic.rawValue) attribute holds \(short.vectorCount) vectors, "
                    + "fewer than the primitive's \(vertex.vectorCount) vertices"
                )
            }

            var elements: [SCNGeometryElement] = []
            if let index = primitive.indices {
                elements.append(try loader.indexAccessor(withAccessorIndex: index, mode: primitive.mode))
            } else {
                elements.append(try vertex.createIndexAccessor(with: primitive.mode))
            }
            for element in elements {
                try element.validateIndices(vertexCount: vertex.vectorCount)
            }

            // glTF has a primitive without NORMAL flat shaded, and a flat normal
            // belongs to a face rather than to a vertex, so every triangle takes
            // its own copy of the three vertices it draws.
            let corners = hasNormal ? nil : try elements.flatMap { try $0.triangleCorners() }
            if let corners {
                let vertices = try vertex.createVertices()
                attributes = try attributes.map { try $0.expanded(to: corners) }
                elements = [.triangles(cornerCount: corners.count)]
                attributes.append(.flatNormals(ofTriangleCorners: corners.map { vertices[$0] }))
            }

            let headVertices = try loader.firstPersonHeadVertices(of: primitive,
                                                                  ofNodeAt: nodeIndex,
                                                                  meshIndex: meshIndex,
                                                                  skinIndex: skinIndex)

            let geometry = SCNGeometry(sources: attributes, elements: elements); do {
                geometry.materials = try {
                    if let materialIndex = primitive.material {
                        return [try loader.material(withMaterialIndex: materialIndex)]
                    } else {
                        return [.default]
                    }
                }()
                node.geometry = geometry

                if let renderQueue = try loader.renderQueue(forMaterialAt: primitive.material),
                   renderQueue != -1 {
                    let lastRenderingOrder = childNodes.last?.renderingOrder ?? 0
                    node.renderingOrder = lastRenderingOrder == 0 ? renderQueue : renderQueue + 1
                }
            }

            let position = primitive.attributes[.POSITION]
            // A morph target moves the vertices of its own primitive, so one whose
            // vertices were unshared shares no morpher with the rest of the mesh.
            let shareable = corners == nil ? position : nil
            if let targets = primitive.targets, !targets.isEmpty {
                let morpher = try SCNMorpher(primitiveTargets: targets, loader: loader, corners: corners)
                node.morpher = morpher
                // The first such primitive is the one the mesh shares, so the
                // ones falling back to it read the morpher already built.
                if let shareable, morphers[shareable] == nil { morphers[shareable] = morpher }
            } else if let position, let targets = sharedTargets[position] {
                let morpher = try shareable.flatMap { morphers[$0] }
                    ?? SCNMorpher(primitiveTargets: targets, loader: loader, corners: corners)
                if let shareable { morphers[shareable] = morpher }
                node.morpher = morpher
            }

            addChildNode(node)

            if let headVertices {
                cuts.append((node, try geometry.firstPersonTriangles(elements: elements,
                                                                     headVertices: headVertices,
                                                                     corners: corners)))
            }
        }

        // After the primitives, so a mesh still lists what the document declares first.
        for (node, cut) in cuts {
            switch cut {
            case .whole:
                break
            case .nothing:
                loader.recordFirstPersonPrimitive(.init(thirdPerson: node, firstPerson: nil))
            case .triangles(let kept):
                let headless = node.standingInForItsFirstPersonTriangles(kept)
                addChildNode(headless)
                loader.recordFirstPersonPrimitive(.init(thirdPerson: node, firstPerson: headless))
            }
        }
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
private extension SCNNode {
    /// A node drawing `triangles` of this one's vertices, which is what a
    /// first-person camera draws in its place.
    func standingInForItsFirstPersonTriangles(_ triangles: [UInt32]) -> SCNNode {
        let headless = SCNNode()
        let geometry = SCNGeometry(sources: self.geometry?.sources ?? [],
                                   elements: [.triangles(triangles)])
        geometry.materials = self.geometry?.materials ?? []
        headless.geometry = geometry
        // The morpher of the node it stands in for, which expressions already drive.
        headless.morpher = morpher
        headless.renderingOrder = renderingOrder
        headless.isHidden = true
        return headless
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
private extension SCNGeometry {
    /// The triangles of this primitive a first-person camera draws: what is left
    /// of an `auto` mesh once the head's are taken out.
    ///
    /// `corners` is what flat shading unshared the vertices into, so a drawn
    /// index still says which vertex it is weighted by.
    func firstPersonTriangles(elements: [SCNGeometryElement],
                              headVertices: Set<Int>,
                              corners: [Int]?) throws -> FirstPersonPrimitiveMask {
        let drawn = try elements.flatMap { try $0.triangleCorners() }.map(UInt32.init)
        let vertex: (UInt32) -> Int = corners.map { corners in { corners[safe: Int($0)] ?? -1 } } ?? { Int($0) }
        return FirstPersonAutoMask.mask(indices: drawn, headVertices: headVertices, vertex: vertex)
    }
}

private extension SCNGeometrySource {
    func createIndexAccessor(with mode: GLTF.Mesh.Primitive.Mode) throws -> SCNGeometryElement {
        guard semantic == .vertex else { throw VRMError._dataInconsistent("semantic is not .vertex but \(semantic)") }
        let primitiveType = try primitiveTypeOf(mode) ??? ._notSupported("\(mode) is not supported")

        let indices = (0..<vectorCount)
        switch UInt64(vectorCount) {
        case ...UInt64(UInt16.max): return SCNGeometryElement(indices: indices.map(UInt16.init), primitiveType: primitiveType)
        case ...UInt64(UInt32.max): return SCNGeometryElement(indices: indices.map(UInt32.init), primitiveType: primitiveType)
        default: return SCNGeometryElement(indices: indices.map(UInt64.init), primitiveType: primitiveType)
        }
    }

    /// The flat normals glTF asks for when a primitive ships no NORMAL: one face
    /// normal written to each of the triangle's three corners.
    ///
    /// - Precondition: the vertices are one per triangle corner, so that each
    ///   triangle owns the ones it writes to.
    static func flatNormals(ofTriangleCorners vertices: [SIMD3<Float>]) -> SCNGeometrySource {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for corner in stride(from: 0, to: vertices.count - vertices.count % 3, by: 3) {
            let faceNormal = simd_cross(vertices[corner + 1] - vertices[corner],
                                        vertices[corner + 2] - vertices[corner])
            let lengthSquared = simd_length_squared(faceNormal)
            // A degenerate triangle keeps a zero normal rather than a NaN one.
            guard lengthSquared.isFinite, lengthSquared > 0 else { continue }
            let normal = simd_normalize(faceNormal)
            normals[corner] = normal
            normals[corner + 1] = normal
            normals[corner + 2] = normal
        }
        return SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
    }
}

private extension SCNGeometryElement {
    func validateIndices(vertexCount: Int) throws {
        if let index = createIndices().first(where: { $0 < 0 || $0 >= vertexCount }) {
            throw VRMError._dataInconsistent(
                "primitive index \(index) is out of range for \(vertexCount) vertices"
            )
        }
    }

    /// A triangle list of the vertices `indices` names.
    static func triangles(_ indices: [UInt32]) -> SCNGeometryElement {
        switch UInt64(indices.max() ?? 0) {
        case ...UInt64(UInt16.max): SCNGeometryElement(indices: indices.map(UInt16.init), primitiveType: .triangles)
        default: SCNGeometryElement(indices: indices, primitiveType: .triangles)
        }
    }

    /// A triangle list of `cornerCount` vertices drawn in the order they are
    /// stored, for a geometry whose vertices a flat shading unshared.
    static func triangles(cornerCount: Int) -> SCNGeometryElement {
        let corners = 0..<cornerCount
        switch UInt64(cornerCount) {
        case ...UInt64(UInt16.max): return SCNGeometryElement(indices: corners.map(UInt16.init), primitiveType: .triangles)
        case ...UInt64(UInt32.max): return SCNGeometryElement(indices: corners.map(UInt32.init), primitiveType: .triangles)
        default: return SCNGeometryElement(indices: corners.map(UInt64.init), primitiveType: .triangles)
        }
    }

    /// The vertices of every triangle the element draws, three to a triangle.
    func triangleCorners() throws -> [Int] {
        var corners: [Int] = []
        try enumerateTriangles { corners.append(contentsOf: [$0, $1, $2]) }
        return corners
    }

    /// Calls `body` with each triangle of the element, expanding a strip into
    /// the triangles it stands for so a mesh without `NORMAL` can be shaded
    /// whichever way its faces are stored.
    private func enumerateTriangles(_ body: (Int, Int, Int) throws -> Void) throws {
        let indices = createIndices()
        switch primitiveType {
        case .triangles:
            for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
                try body(indices[triangle], indices[triangle + 1], indices[triangle + 2])
            }
        case .triangleStrip:
            // Consecutive triangles of a strip alternate winding, so every odd
            // one swaps its first two vertices to keep the faces consistent.
            for triangle in 0..<max(0, indices.count - 2) {
                let (first, second) = triangle.isMultiple(of: 2)
                    ? (indices[triangle], indices[triangle + 1])
                    : (indices[triangle + 1], indices[triangle])
                try body(first, second, indices[triangle + 2])
            }
        default:
            throw VRMError._notSupported("only triangles type is supported: \(primitiveType)")
        }
    }

    func createIndices() -> [Int] {
        let indexCount = data.count / bytesPerIndex
        var indices: [Int] = []
        indices.reserveCapacity(indexCount)

        func createIndices<T: UnsignedInteger>(_ type: T.Type = T.self, rawPtr: UnsafeRawBufferPointer) {
            guard let ptr = rawPtr.bindMemory(to: T.self).baseAddress else { return }
            for i in 0..<indexCount {
                indices.append(Int(ptr[i]))
            }
        }

        switch bytesPerIndex {
        case MemoryLayout<UInt8>.size:
            data.withUnsafeBytes { createIndices(UInt8.self, rawPtr: $0) }
        case MemoryLayout<UInt16>.size:
            data.withUnsafeBytes { createIndices(UInt16.self, rawPtr: $0) }
        case MemoryLayout<UInt32>.size:
            data.withUnsafeBytes { createIndices(UInt32.self, rawPtr: $0) }
        case MemoryLayout<UInt64>.size:
            data.withUnsafeBytes { createIndices(UInt64.self, rawPtr: $0) }
        default: ()
        }

        return indices
    }
}
