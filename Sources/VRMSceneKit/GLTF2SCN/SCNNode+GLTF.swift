import VRMKit
import SceneKit
import simd

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNNode {
    convenience init(node: GLTF.Node, loader: VRMSceneLoader) throws {
        self.init()
        name = node.name
        camera = try node.camera.map(loader.camera)

        if let mesh = node.mesh {
            let meshNode = try loader.mesh(withMeshIndex: mesh)
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

    convenience init(mesh: GLTF.Mesh, loader: VRMSceneLoader) throws {
        self.init()
        name = mesh.name
        var morpher: SCNMorpher?

        for primitive in mesh.primitives {
            let node = SCNNode()
            var attributes = try loader.attributes(primitive.attributes.rawValue)
            let vertex = try attributes.first { $0.semantic == .vertex }
                ??? ._dataInconsistent("a mesh primitive has no POSITION attribute")
            let hasNormal = attributes.contains { $0.semantic == .normal }

            var elements: [SCNGeometryElement] = []
            if let index = primitive.indices {
                elements.append(try loader.indexAccessor(withAccessorIndex: index, mode: primitive.mode))
            } else {
                elements.append(try vertex.createIndexAccessor(with: primitive.mode))
            }
            for element in elements {
                try element.validateIndices(vertexCount: vertex.vectorCount)
            }

            if !hasNormal {
                attributes.append(try vertex.createEstimatedNormal(with: elements))
            }

            let geometry = SCNGeometry(sources: attributes, elements: elements); do {
                geometry.materials = try {
                    if let materialIndex = primitive.material {
                        return [try loader.material(withMaterialIndex: materialIndex)]
                    } else {
                        return [.default]
                    }
                }()
                node.geometry = geometry

                // FIXME/TODO:
                if let renderQueue = try loader.renderQueue(forMaterialAt: primitive.material),
                   renderQueue != -1 {
                    let lastRenderingOrder = childNodes.last?.renderingOrder ?? 0
                    node.renderingOrder = lastRenderingOrder == 0 ? renderQueue : renderQueue + 1
                }
            }

            if let targets = primitive.targets, !targets.isEmpty {
                morpher = try SCNMorpher(primitiveTargets: targets, loader: loader)
                node.morpher = morpher
//                let path = "childNodes[0].childNodes[\(primitiveIndex)].morpher.weights[\(index)]"
            } else {
                node.morpher = morpher
            }

            addChildNode(node)
        }
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

    func createEstimatedNormal(with elements: [SCNGeometryElement]) throws -> SCNGeometrySource {
        let vertices = try createVertices()
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        for element in elements {
            try element.enumerateTriangles { index0, index1, index2 in
                let faceNormal = simd_cross(vertices[index1] - vertices[index0],
                                            vertices[index2] - vertices[index0])
                let lengthSquared = simd_length_squared(faceNormal)
                guard lengthSquared.isFinite, lengthSquared > 0 else { return }
                let normalized = simd_normalize(faceNormal)
                normals[index0] += normalized
                normals[index1] += normalized
                normals[index2] += normalized
            }
        }

        for index in normals.indices {
            let lengthSquared = simd_length_squared(normals[index])
            if lengthSquared.isFinite, lengthSquared > 0 {
                normals[index] = simd_normalize(normals[index])
            }
        }
        return SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
    }

    func createVertices() throws -> [SIMD3<Float>] {
        guard componentsPerVector == 3 else { throw VRMError._notSupported("vertex array is support for 3 component only: \(componentsPerVector)") }
        if !usesFloatComponents || bytesPerComponent != 4 { throw VRMError._notSupported("vertex array is support for float components only") }

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(vectorCount)
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.bindMemory(to: Float32.self).baseAddress else { return }
            var index = dataOffset / bytesPerComponent
            let step = dataStride / bytesPerComponent
            for _ in 0..<vectorCount {
                vertices.append(SIMD3<Float>(ptr[index], ptr[index + 1], ptr[index + 2]))
                index += step
            }
        }
        return vertices
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

    /// Calls `body` with each triangle of the element, expanding a strip into
    /// the triangles it stands for so a mesh without `NORMAL` can be shaded
    /// whichever way its faces are stored.
    func enumerateTriangles(_ body: (Int, Int, Int) throws -> Void) throws {
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
