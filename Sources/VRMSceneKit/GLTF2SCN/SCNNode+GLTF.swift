import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNNode {
    convenience init(node: GLTF.Node, skins: [GLTF.Skin]?, loader: VRMSceneLoader) throws {
        self.init()
        name = node.name
        camera = try node.camera.map(loader.camera)

        if let mesh = node.mesh {
            let meshNode = try loader.mesh(withMeshIndex: mesh)
            addChildNode(meshNode)

            if let skinIndex = node.skin, let skin = skins?[skinIndex] {
                let joints = try skin.joints.map(loader.node)
                let ibm = try skin.inverseBindMatrices.map(loader.inverseBindMatrix)
                let skeleton = try skin.skeleton.map(loader.node)
                for primitive in meshNode.childNodes {
                    guard let geometry = primitive.geometry,
                          geometry.hasSkinningSources else {
                        continue
                    }
                    primitive.skinner = try loader.skin(
                        withSkinIndex: skinIndex,
                        primitiveGeometry: geometry,
                        bones: joints,
                        boneInverseBindTransform: ibm)
                    primitive.skinner?.skeleton = skeleton ?? primitive
                }
            }
        }

        if let matrix = node._matrix {
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

        for (primitiveIndex, primitive) in mesh.primitives.enumerated() {
            let node = SCNNode()
            let materialIndex = primitive.material
            var attributes = try loader.attributes(primitive.attributes.rawValue)
            let vertex = attributes.first { $0.semantic == .vertex }
            let hasNormal = attributes.contains { $0.semantic == .normal }

            var elements: [SCNGeometryElement] = []
            if let index = primitive.indices {
                elements.append(try loader.indexAccessor(withAccessorIndex: index, mode: primitive.mode))
            } else if let vertex = vertex {
                elements.append(try vertex.createIndexAccessor(with: primitive.mode))
            }

            if !hasNormal, let vertex = vertex {
                attributes.append(try vertex.createEstimatedNormal(with: elements))
            }

            let geometry = SCNGeometry(sources: attributes, elements: elements); do {
                geometry.materials = try {
                    if let materialIndex {
                        return [try loader.material(withMaterialIndex: materialIndex)]
                    } else {
                        return [.default]
                    }
                }()
                node.geometry = geometry

                // FIXME/TODO:
                if let renderQueue = try loader.renderQueue(forMaterialNamed: geometry.materials[0].name),
                   renderQueue != -1 {
                    node.renderingOrder = scnRenderingOrder(forRenderQueue: renderQueue,
                                                            primitiveIndex: primitiveIndex)
                }
            }

            if let targets = primitive.targets, !targets.isEmpty {
                morpher = try SCNMorpher(primitiveTargets: targets, baseSources: attributes, loader: loader)
                node.morpher = morpher
//                let path = "childNodes[0].childNodes[\(primitiveIndex)].morpher.weights[\(index)]"
            } else {
                node.morpher = morpher
            }

            addChildNode(node)
            if let materialIndex,
               let outlineMaterial = node.geometry?.materials.first?.mtoonOutlineMaterial(),
               let outlineGeometry = node.geometry?.copy() as? SCNGeometry {
                outlineGeometry.materials = [outlineMaterial]
                let outlineNode = SCNNode(geometry: outlineGeometry)
                outlineNode.name = node.name.map { "\($0)_outline" }
                if let targets = primitive.targets, !targets.isEmpty {
                    outlineNode.morpher = try SCNMorpher(primitiveTargets: targets,
                                                         baseSources: attributes,
                                                         loader: loader)
                }
                outlineNode.renderingOrder = node.renderingOrder == 0 ? 1 : node.renderingOrder + 1
                loader.registerMToonOutlineMaterial(outlineMaterial, materialIndex: materialIndex)
                addChildNode(outlineNode)
            }
        }
    }
}

private let scnRenderingOrderQueueStride = 10_000
private let scnRenderingOrderPrimitiveStride = 2

private func scnRenderingOrder(forRenderQueue renderQueue: Int, primitiveIndex: Int) -> Int {
    return renderQueue * scnRenderingOrderQueueStride + primitiveIndex * scnRenderingOrderPrimitiveStride
}

private extension SCNGeometry {
    var hasSkinningSources: Bool {
        sources(for: .boneWeights).first != nil && sources(for: .boneIndices).first != nil
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
        var normals = [SCNVector3](repeating: SCNVector3(), count: vertices.count)

        for element in elements {
            guard element.primitiveType == .triangles else { throw VRMError._notSupported("only triangles type is supported: \(element.primitiveType)") }

            let indices = element.createIndices()

            for indexPos in stride(from: 0, to: indices.count, by: 3) {
                let index0 = indices[indexPos]
                let index1 = indices[indexPos + 1]
                let index2 = indices[indexPos + 2]

                let vertex0 = vertices[index0]
                let vertex1 = vertices[index1]
                let vertex2 = vertices[index2]

                let _normal = normal(vertex0, vertex1, vertex2)
                normals[index0] += _normal
                normals[index1] += _normal
                normals[index2] += _normal
            }
        }

        for i in 0..<normals.count {
            normals[i] = normals[i].normalized
        }
        return SCNGeometrySource(normals: normals)
    }

    func createVertices() throws -> [SCNVector3] {
        guard componentsPerVector == 3 else { throw VRMError._notSupported("vertex array is support for 3 component only: \(componentsPerVector)") }
        if !usesFloatComponents || bytesPerComponent != 4 { throw VRMError._notSupported("vertex array is support for float components only") }

        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(vectorCount)
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.bindMemory(to: Float32.self).baseAddress else { return }
            var index = dataOffset / bytesPerComponent
            let step = dataStride / bytesPerComponent
            for _ in 0..<vectorCount {
                vertices.append(SCNVector3(ptr[index + 0], ptr[index + 1], ptr[index + 2]))
                index += step
            }
        }
        return vertices
    }
}

private extension SCNGeometryElement {
    func createIndices() -> [Int] {
        let indexCount = primitiveCount * 3
        var indices: [Int] = []
        indices.reserveCapacity(indexCount)

        func createIndices<T: UnsignedInteger>(_ type: T.Type = T.self, rawPtr: UnsafeRawBufferPointer) {
            guard let ptr = rawPtr.bindMemory(to: T.self).baseAddress else { return }
            for i in 0..<indexCount {
                indices.append(Int(ptr[i]))
            }
        }

        typealias Func<T> = (UnsafePointer<T>) -> Void

        switch bytesPerIndex {
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
