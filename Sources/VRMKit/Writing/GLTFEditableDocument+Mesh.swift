import Foundation
import simd

extension GLTFEditableDocument {
    /// Adds a node drawing `mesh`, and returns its index.
    ///
    /// The placement is ``addNode(name:parent:transform:)``'s, so
    /// `GLTFEditableDocument()` followed by one `addMesh` is a whole asset. The
    /// vertex data is packed tightly into the BIN buffer and written as one
    /// triangle primitive over it, and a VRM 0.x model gets the
    /// `materialProperties` entry that keeps that array parallel to its materials.
    ///
    /// A mesh glTF cannot describe is refused and the document left as it was.
    /// See ``GLTFTriangleMesh`` for what that rules out.
    @discardableResult
    public mutating func addMesh(_ mesh: GLTFTriangleMesh,
                        under parentNode: GLTFNodeIndex? = nil,
                        name: String? = nil,
                        transform: GLTFNodeTransform = .identity,
                        materials: GLTFMaterialConversion = .keep) throws -> GLTFNodeIndex {
        // Resolve everything that can fail before any resource is appended. The
        // MToon conversion can still fail once the mesh has been written.
        let validated = try mesh.validate()
        try transform.validate()
        let placement = try resolveNodePlacement(under: parentNode?.rawValue)

        return try atomically { document in
            let material = try mesh.material.map { try document.appendMaterial($0, mediaType: validated.imageMediaType) }
            let primitive = document.appendPrimitive(of: mesh, validated: validated, material: material)

            var meshObject = JSONObject()
            meshObject.set("name", name)
            meshObject["primitives"] = .objects([primitive])
            let meshIndex = document.json.appendObject(meshObject, to: .meshes)

            var node = JSONObject()
            node.set("name", name)
            transform.write(into: &node)
            node["mesh"] = .int(meshIndex)
            let index = document.appendNode(node, at: placement)

            if case .mtoon(let style) = materials, let material {
                try document.convertMaterialsToMToon(at: [GLTFMaterialIndex(material)], style: style)
            }
            return GLTFNodeIndex(index)
        }
    }

    // MARK: - Primitive

    /// `mode` is left out: 4, triangles, is what glTF defaults to.
    private mutating func appendPrimitive(of mesh: GLTFTriangleMesh,
                                 validated: ValidatedTriangleMesh,
                                 material: Int?) -> JSONObject {
        var attributePayloads: [(name: String, payload: AccessorPayload)] = [
            ("POSITION", AccessorPayload(data: Self.packed(mesh.positions),
                                         type: .VEC3,
                                         componentType: .float,
                                         count: mesh.positions.count,
                                         target: .arrayBuffer,
                                         bounds: validated.positionBounds))
        ]
        if let normals = mesh.normals {
            attributePayloads.append(("NORMAL", AccessorPayload(data: Self.packed(normals),
                                                                 type: .VEC3,
                                                                 componentType: .float,
                                                                 count: normals.count,
                                                                 target: .arrayBuffer)))
        }
        if let textureCoordinates = mesh.textureCoordinates {
            attributePayloads.append(("TEXCOORD_0", AccessorPayload(data: Self.packed(textureCoordinates),
                                                                     type: .VEC2,
                                                                     componentType: .float,
                                                                     count: textureCoordinates.count,
                                                                     target: .arrayBuffer)))
        }

        let payloads = attributePayloads.map(\.payload)
            + [Self.indexPayload(mesh.indices, maximum: validated.maximumIndex)]
        let accessorIndices = appendAccessors(payloads)
        var attributes = JSONObject()
        for (attribute, index) in zip(attributePayloads, accessorIndices) {
            attributes[attribute.name] = .int(index)
        }
        var primitive: JSONObject = ["attributes": .object(attributes),
                                     "indices": .int(accessorIndices[attributePayloads.count])]
        primitive.set("material", material)
        return primitive
    }

    /// `UInt16` where the indices fit in one, and `UInt32` where they do not.
    /// `UInt16.max` is glTF's primitive restart value, so a mesh reaching it is
    /// written wide.
    private static func indexPayload(_ indices: [UInt32], maximum: UInt32) -> AccessorPayload {
        guard maximum >= UInt32(UInt16.max) else {
            return AccessorPayload(data: packedIntegers(indices, as: UInt16.self),
                                   type: .SCALAR,
                                   componentType: .unsignedShort,
                                   count: indices.count,
                                   target: .elementArrayBuffer)
        }
        return AccessorPayload(data: packedIntegers(indices, as: UInt32.self),
                               type: .SCALAR,
                               componentType: .unsignedInt,
                               count: indices.count,
                               target: .elementArrayBuffer)
    }

    /// The `target` a buffer view names the GPU buffer it belongs in with.
    private enum BufferViewTarget: Int {
        case arrayBuffer = 34962
        case elementArrayBuffer = 34963
    }

    private struct AccessorPayload {
        let data: Data
        let type: GLTF.Accessor.`Type`
        let componentType: GLTF.Accessor.ComponentType
        let count: Int
        let target: BufferViewTarget
        var bounds: (min: [Float], max: [Float])?

        init(data: Data,
             type: GLTF.Accessor.`Type`,
             componentType: GLTF.Accessor.ComponentType,
             count: Int,
             target: BufferViewTarget,
             bounds: (min: [Float], max: [Float])? = nil) {
            self.data = data
            self.type = type
            self.componentType = componentType
            self.count = count
            self.target = target
            self.bounds = bounds
        }
    }

    /// Appends each payload to the BIN buffer as a buffer view of its own, with
    /// an accessor over the whole of it. Tightly packed, so no `byteStride`: glTF
    /// reads a missing one as the accessor's element size.
    private mutating func appendAccessors(_ payloads: [AccessorPayload]) -> [Int] {
        let viewBase = json.count(.bufferViews)
        let accessorBase = json.count(.accessors)
        var views: [JSONObject] = []
        var accessors: [JSONObject] = []
        views.reserveCapacity(payloads.count)
        accessors.reserveCapacity(payloads.count)

        for payload in payloads {
            views.append(["buffer": 0,
                          "byteOffset": .int(appendToBinary(payload.data)),
                          "byteLength": .int(payload.data.count),
                          "target": .int(payload.target.rawValue)])
            var accessor: JSONObject = ["bufferView": .int(viewBase + views.count - 1),
                                        "componentType": .int(payload.componentType.rawValue),
                                        "count": .int(payload.count),
                                        "type": .string(payload.type.rawValue)]
            if let bounds = payload.bounds {
                accessor["min"] = .numbers(bounds.min)
                accessor["max"] = .numbers(bounds.max)
            }
            accessors.append(accessor)
        }
        json.appendObjects(views, to: .bufferViews)
        json.appendObjects(accessors, to: .accessors)
        return payloads.indices.map { accessorBase + $0 }
    }

    private static func packed<Vector: SIMD>(_ values: [Vector]) -> Data where Vector.Scalar == Float {
        let byteCount = values.count * Vector.scalarCount * MemoryLayout<UInt32>.size
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { buffer in
            var offset = 0
            for value in values {
                for component in 0..<Vector.scalarCount {
                    buffer.storeBytes(of: value[component].bitPattern.littleEndian,
                                      toByteOffset: offset,
                                      as: UInt32.self)
                    offset += MemoryLayout<UInt32>.size
                }
            }
        }
        return data
    }

    private static func packedIntegers<Integer: FixedWidthInteger>(_ values: [UInt32], as: Integer.Type) -> Data {
        let byteCount = values.count * MemoryLayout<Integer>.size
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { buffer in
            for (index, value) in values.enumerated() {
                buffer.storeBytes(of: Integer(truncatingIfNeeded: value).littleEndian,
                                  toByteOffset: index * MemoryLayout<Integer>.size,
                                  as: Integer.self)
            }
        }
        return data
    }

    // MARK: - Material

    /// Writes the material and whatever it needs: an image, a texture, an
    /// extension declaration, a VRM 0.x property.
    private mutating func appendMaterial(_ material: GLTFSimpleMaterial, mediaType: String?) throws -> Int {
        // glTF defaults a material to fully metallic, which is a mirror rather
        // than the plate this builds.
        var pbr: JSONObject = ["metallicFactor": 0]
        let color = material.baseColorFactor
        if color != SIMD4(1, 1, 1, 1) {
            pbr["baseColorFactor"] = .simd(color)
        }
        if let image = material.baseColorImage, let mediaType {
            let texture = appendTexture(image, mediaType: mediaType, sampler: material.baseColorSampler)
            pbr["baseColorTexture"] = ["index": .int(texture)]
        }

        var object: JSONObject = ["pbrMetallicRoughness": .object(pbr)]
        object.set("name", material.name)
        switch material.alphaMode {
        case .opaque:
            break  // OPAQUE is what glTF reads a material naming no mode as.
        case .mask(let cutoff):
            object["alphaMode"] = .string(GLTF.Material.AlphaMode.MASK.rawValue)
            object["alphaCutoff"] = .number(cutoff)
        case .blend:
            object["alphaMode"] = .string(GLTF.Material.AlphaMode.BLEND.rawValue)
        }
        if material.isDoubleSided {
            object["doubleSided"] = true
        }
        if material.isUnlit {
            object["extensions"] = [GLTFExtension.materialsUnlit.rawValue: .object([:])]
            declareExtensions(used: [GLTFExtension.materialsUnlit.rawValue])
        }

        let index = json.appendObject(object, to: .materials)
        try appendVRM0MaterialProperties(named: [material.name])
        return index
    }
}
