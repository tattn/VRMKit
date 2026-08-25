import Foundation
import simd

extension GLTFEditableDocument {
    /// Adds a node drawing `mesh`, and returns its index.
    ///
    /// The placement is ``addNode(name:parent:transform:)``'s, so with no
    /// `parentNode` the node becomes a root of the default scene and a document
    /// holding no scene is given one. `GLTFEditableDocument()` followed by one
    /// `addMesh` is therefore a whole asset.
    ///
    /// The vertex data is packed tightly into the BIN buffer and written as one
    /// triangle primitive over it. Nothing already in the document moves, and a
    /// VRM 0.x model gets the `materialProperties` entry that keeps that array
    /// parallel to its materials. `materials` writes the mesh's material as MToon
    /// rather than as the PBR it describes, as it does for `append`.
    ///
    /// A mesh glTF cannot describe is refused and the document left as it was.
    /// See ``GLTFTriangleMesh`` for what that rules out.
    @discardableResult
    public func addMesh(_ mesh: GLTFTriangleMesh,
                        under parentNode: Int? = nil,
                        name: String? = nil,
                        transform: GLTFNodeTransform = .identity,
                        materials: GLTFMaterialConversion = .keep) throws -> Int {
        // Resolve everything that can fail before any resource is appended. The
        // MToon conversion can still fail once the mesh has been written.
        let validated = try mesh.validate()
        try transform.validate()
        let placement = try resolveNodePlacement(under: parentNode)

        return try atomicallyAppendingBinary {
            let material = try mesh.material.map { try appendMaterial($0, mediaType: validated.imageMediaType) }
            let primitive = appendPrimitive(of: mesh, validated: validated, material: material)

            var meshObject = JSONObject()
            meshObject.set("name", name)
            meshObject["primitives"] = [primitive]
            let meshIndex = json.appendObject(meshObject, to: .meshes)

            var node = JSONObject()
            node.set("name", name)
            transform.write(into: &node)
            node["mesh"] = meshIndex
            let index = appendNode(node, at: placement)

            if case .mtoon(let style) = materials, let material {
                try convertMaterialsToMToon(at: [material], style: style)
            }
            return index
        }
    }

    // MARK: - Primitive

    /// `mode` is left out: 4, triangles, is what glTF defaults to.
    private func appendPrimitive(of mesh: GLTFTriangleMesh,
                                 validated: ValidatedTriangleMesh,
                                 material: Int?) -> JSONObject {
        var attributePayloads: [(name: String, payload: AccessorPayload)] = [
            ("POSITION", AccessorPayload(data: packed(mesh.positions),
                                         type: .VEC3,
                                         componentType: .float,
                                         count: mesh.positions.count,
                                         target: .arrayBuffer,
                                         bounds: validated.positionBounds))
        ]
        if let normals = mesh.normals {
            attributePayloads.append(("NORMAL", AccessorPayload(data: packed(normals),
                                                                 type: .VEC3,
                                                                 componentType: .float,
                                                                 count: normals.count,
                                                                 target: .arrayBuffer)))
        }
        if let textureCoordinates = mesh.textureCoordinates {
            attributePayloads.append(("TEXCOORD_0", AccessorPayload(data: packed(textureCoordinates),
                                                                     type: .VEC2,
                                                                     componentType: .float,
                                                                     count: textureCoordinates.count,
                                                                     target: .arrayBuffer)))
        }

        let payloads = attributePayloads.map(\.payload)
            + [indexPayload(mesh.indices, maximum: validated.maximumIndex)]
        let accessorIndices = appendAccessors(payloads)
        var attributes = JSONObject()
        for (attribute, index) in zip(attributePayloads, accessorIndices) {
            attributes[attribute.name] = index
        }
        var primitive: JSONObject = ["attributes": attributes,
                                     "indices": accessorIndices[attributePayloads.count]]
        primitive.set("material", material)
        return primitive
    }

    /// `UInt16` where the indices fit in one, and `UInt32` where they do not.
    /// `UInt16.max` is glTF's primitive restart value, so a mesh reaching it is
    /// written wide.
    private func indexPayload(_ indices: [UInt32], maximum: UInt32) -> AccessorPayload {
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
    private func appendAccessors(_ payloads: [AccessorPayload]) -> [Int] {
        let viewBase = json.count(.bufferViews)
        let accessorBase = json.count(.accessors)
        var views: [JSONObject] = []
        var accessors: [JSONObject] = []
        views.reserveCapacity(payloads.count)
        accessors.reserveCapacity(payloads.count)

        for payload in payloads {
            views.append(["buffer": 0,
                          "byteOffset": appendToBinary(payload.data),
                          "byteLength": payload.data.count,
                          "target": payload.target.rawValue])
            var accessor: JSONObject = ["bufferView": viewBase + views.count - 1,
                                        "componentType": payload.componentType.rawValue,
                                        "count": payload.count,
                                        "type": payload.type.rawValue]
            if let bounds = payload.bounds {
                accessor["min"] = bounds.min
                accessor["max"] = bounds.max
            }
            accessors.append(accessor)
        }
        json.appendObjects(views, to: .bufferViews)
        json.appendObjects(accessors, to: .accessors)
        return payloads.indices.map { accessorBase + $0 }
    }

    private func packed<Vector: SIMD>(_ values: [Vector]) -> Data where Vector.Scalar == Float {
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

    private func packedIntegers<Integer: FixedWidthInteger>(_ values: [UInt32], as: Integer.Type) -> Data {
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
    private func appendMaterial(_ material: GLTFSimpleMaterial, mediaType: String?) throws -> Int {
        // glTF defaults a material to fully metallic, which is a mirror rather
        // than the plate this builds.
        var pbr: JSONObject = ["metallicFactor": 0]
        let color = material.baseColorFactor
        if color != SIMD4(1, 1, 1, 1) {
            pbr["baseColorFactor"] = [color.x, color.y, color.z, color.w]
        }
        if let image = material.baseColorImage, let mediaType {
            let texture = appendTexture(image, mediaType: mediaType, sampler: material.baseColorSampler)
            pbr["baseColorTexture"] = ["index": texture]
        }

        var object: JSONObject = ["pbrMetallicRoughness": pbr]
        object.set("name", material.name)
        switch material.alphaMode {
        case .opaque:
            break  // OPAQUE is what glTF reads a material naming no mode as.
        case .mask(let cutoff):
            object["alphaMode"] = GLTF.Material.AlphaMode.MASK.rawValue
            object["alphaCutoff"] = cutoff
        case .blend:
            object["alphaMode"] = GLTF.Material.AlphaMode.BLEND.rawValue
        }
        if material.isDoubleSided {
            object["doubleSided"] = true
        }
        if material.isUnlit {
            object["extensions"] = [GLTFExtension.materialsUnlit.rawValue: JSONObject()]
            declareExtensions(used: [GLTFExtension.materialsUnlit.rawValue])
        }

        let index = json.appendObject(object, to: .materials)
        try appendVRM0MaterialProperties(named: [material.name])
        return index
    }
}
