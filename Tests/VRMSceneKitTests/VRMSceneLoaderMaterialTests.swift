import VRMKit
import VRMTestSupport
import simd
@testable import VRMSceneKit
import SceneKit
import Testing

@Suite
struct VRMSceneLoaderMaterialTests {
    /// glTF lets several nodes draw one mesh while an `SCNNode` belongs to one parent,
    /// so sharing a node would leave the first of them empty.
    @Test
    func testAMeshDrawnByTwoNodesAppearsUnderBoth() throws {
        let original = try GLTFDocument(data: VRMSampleAsset.aliciaSolid.data).gltf.nodes
        let drawing = try #require(original.firstIndex { $0.mesh != nil })
        let instanced = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var nodes = json.objects(.nodes)
            var second: JSONObject = ["name": "second draw"]
            second["mesh"] = nodes[drawing]["mesh"]
            nodes.append(second)
            json.setObjects(nodes, for: .nodes)
            json.mapObjects(.scenes) { scene in
                var scene = scene
                scene["nodes"] = .numbers((scene.ints("nodes") ?? []) + [nodes.count - 1])
                return scene
            }
        }

        let loader = try VRMSceneLoader(withData: instanced)
        _ = try loader.loadScene()

        let first = try loader.node(withNodeIndex: drawing)
        let second = try loader.node(withNodeIndex: original.count)
        #expect(second.name == "second draw")
        #expect(!first.childNodes.isEmpty)
        #expect(!second.childNodes.isEmpty)
        #expect(first.childNodes[0] !== second.childNodes[0])
        // The primitives under each hold the geometry.
        #expect(first.childNodes[0].childNodes.first?.geometry != nil)
        #expect(second.childNodes[0].childNodes.first?.geometry != nil)
        #expect(first.childNodes[0].childNodes.first !== second.childNodes[0].childNodes.first)
    }

    /// `VRM_USE_GLTFSHADER` asks for the glTF material as it is, which is what a plain
    /// glTF prop appended to a VRM 0.x avatar gets.
    @Test
    func testAGLTFShaderMaterialIsShadedAsGLTFRatherThanFlat() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let appendedIndex = try document.typed().materials.count
        try document.append(try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url), under: 0)

        let loader = try VRMSceneLoader(withData: try document.serialize())

        #expect(try loader.material(withMaterialIndex: appendedIndex).lightingModel == .physicallyBased)
        // The avatar's own materials still shade the way VRM 0.x asks.
        #expect(try loader.material(withMaterialIndex: 0).lightingModel == .constant)
    }

    /// A model painting its vertices is drawn with them: SceneKit multiplies the
    /// material's diffuse by the colour source, as glTF has COLOR_0 do.
    @Test
    func testVertexColoursReachTheGeometry() throws {
        let coloured = try VRMSampleAsset.seedSan.rewritingJSON { json in
            json.mapObjects(.meshes) { mesh in
                var mesh = mesh
                mesh.mapObjects("primitives") { primitive in
                    var primitive = primitive
                    primitive.withObject("attributes") { $0["COLOR_0"] = $0["NORMAL"] }
                    return primitive
                }
                return mesh
            }
        }
        let loader = try VRMSceneLoader(withData: coloured)

        let geometry = try #require(try loader.mesh(withMeshIndex: 0, skinIndex: nil, nodeIndex: 0).childNodes.first?.geometry)

        let colours = try #require(geometry.sources(for: .color).first)
        #expect(colours.componentsPerVector == 3)
        #expect(colours.vectorCount == geometry.sources(for: .vertex).first?.vectorCount)
    }

    /// Every attribute describes the same vertices. One holding fewer would be read past
    /// its end, so it fails the load instead.
    @Test
    func testAVertexAttributeShorterThanPositionFailsTheLoad() throws {
        let document = try GLTFDocument(data: VRMSampleAsset.seedSan.data)
        let normal = try #require(document.gltf.meshes.first?.primitives.first?.attributes[.NORMAL])
        let short = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var accessors = json.objects(.accessors)
            accessors[normal]["count"] = 1
            json.setObjects(accessors, for: .accessors)
        }
        let loader = try VRMSceneLoader(withData: short)

        #expect(throws: VRMError.self) { try loader.mesh(withMeshIndex: 0, skinIndex: nil, nodeIndex: 0) }
    }

    /// An `auto` mesh keeps the triangles no head bone draws, and a primitive the head
    /// draws whole goes with it.
    @Test
    func testFirstPersonAutoDrawsAMeshWithoutTheHeadsTriangles() throws {
        // Alicia annotates every mesh `Auto`, hers being split head from body.
        let loader = try VRMSceneLoader(withData: VRMSampleAsset.aliciaSolid.data)
        let vrmNode = try loader.loadScene().vrmNode

        let thirdPerson = vrmNode.drawnPrimitives
        vrmNode.setFirstPersonRenderMode(.firstPerson)
        let firstPerson = vrmNode.drawnPrimitives

        // The body is still drawn, the head is not, and one primitive draws part of what
        // it did through a node standing in for it.
        #expect(!firstPerson.isEmpty)
        #expect(firstPerson.values.reduce(0, +) < thirdPerson.values.reduce(0, +))
        #expect(!Set(thirdPerson.keys).subtracting(firstPerson.keys).isEmpty)
        let standIn = try #require(Set(firstPerson.keys).subtracting(thirdPerson.keys).first)
        #expect(firstPerson[standIn]! > 0)

        vrmNode.setFirstPersonRenderMode(.thirdPerson)
        #expect(vrmNode.drawnPrimitives == thirdPerson)
    }

    /// glTF multiplies the textures a material samples by the factors beside them, none
    /// of which SceneKit applies on its own.
    @Test
    func testTheFactorsBesideATexturedMaterialsSlotsAreApplied() throws {
        let index = 7
        let data = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var materials = json.objects(.materials)
            materials[index] = [
                "name": "factors",
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.5, 0.25, 0.125, 1],
                    "baseColorTexture": ["index": 0],
                    "metallicFactor": 0.5,
                    "roughnessFactor": 0.25,
                    "metallicRoughnessTexture": ["index": 0],
                ],
                "emissiveFactor": [0.5, 0.25, 0],
                "emissiveTexture": ["index": 0],
                "alphaMode": "MASK",
                "alphaCutoff": 0.25,
            ]
            json.setObjects(materials, for: .materials)
        }
        let loader = try VRMSceneLoader(withData: data)

        let material = try loader.material(withMaterialIndex: index)

        let tint = try #require(material.multiply.contents as? VRMColor).simd
        #expect(simd_distance(tint, SIMD4<Float>(0.5, 0.25, 0.125, 1)) < 1e-4)
        // The strongest channel of the emissive factor is as much as an intensity carries.
        #expect(abs(material.emission.intensity - 0.5) < 1e-4)
        // Nothing between transparent and opaque survives a cutoff.
        #expect(material.blendMode == .replace)
        #expect(material.shaderModifiers?[.fragment]?.contains("0.25") == true)
    }

    /// A material emitting a colour of its own emits it without a texture to sample,
    /// which SceneKit reads off the same property.
    @Test
    func testAnUntexturedEmissiveFactorIsTheEmittedColour() throws {
        let index = 7
        let data = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var materials = json.objects(.materials)
            materials[index] = ["name": "emissive", "emissiveFactor": [1, 0.5, 0]]
            json.setObjects(materials, for: .materials)
        }
        let loader = try VRMSceneLoader(withData: data)

        let emission = try loader.material(withMaterialIndex: index).emission
        let colour = try #require(emission.contents as? VRMColor).simd

        #expect(simd_distance(colour, SIMD4<Float>(1, 0.5, 0, 1)) < 1e-4)
    }

    /// An `SCNGeometrySource` carries the semantic it was built for, so a cache keyed by
    /// accessor alone would hand the second attribute the first's source.
    @Test
    func testAnAccessorReadAsTwoSemanticsGivesEachItsOwnSource() throws {
        let shared = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            json.mapObjects(.meshes) { mesh in
                var mesh = mesh
                mesh.mapObjects("primitives") { primitive in
                    var primitive = primitive
                    primitive.withObject("attributes") { $0["NORMAL"] = $0["POSITION"] }
                    return primitive
                }
                return mesh
            }
        }
        let loader = try VRMSceneLoader(withData: shared)
        let position = try #require(try GLTFDocument(data: shared).gltf.meshes.first?
            .primitives.first?.attributes[.POSITION])

        let sources = try loader.attributes([.POSITION: position, .NORMAL: position])

        #expect(Set(sources.map(\.semantic)) == [.vertex, .normal])
        #expect(sources.count == 2)
    }

    /// glTF indices are unsigned, checked the way the RealityKit loader checks them
    /// rather than by only rejecting floats.
    @Test
    func testAnIndexAccessorWithSignedComponentsFailsTheLoad() throws {
        let document = try GLTFDocument(data: VRMSampleAsset.aliciaSolid.data)
        let accessorIndex = try #require(document.gltf.meshes.first?.primitives.first?.indices)
        let signed = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var accessors = json.objects(.accessors)
            accessors[accessorIndex]["componentType"] = 5122  // SHORT
            json.setObjects(accessors, for: .accessors)
        }
        let loader = try VRMSceneLoader(withData: signed)

        #expect(throws: VRMError.self) { try loader.loadScene() }
    }

    /// A skin claiming more inverse bind matrices than its buffer view holds fails the
    /// load rather than reading past it.
    @Test
    func testInverseBindMatricesBeyondTheirBufferViewFailTheLoad() throws {
        let document = try GLTFDocument(data: VRMSampleAsset.aliciaSolid.data)
        let accessorIndex = try #require(document.gltf.skins.compactMap(\.inverseBindMatrices).first)
        let overrunning = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var accessors = json.objects(.accessors)
            accessors[accessorIndex]["count"] = 1_000_000
            json.setObjects(accessors, for: .accessors)
        }
        let loader = try VRMSceneLoader(withData: overrunning)

        #expect(throws: VRMError.self) { try loader.inverseBindMatrix(withAccessorIndex: accessorIndex) }
    }

    /// A `VRM_USE_GLTFSHADER` entry carries no meaningful Unity queue, so the order
    /// follows the glTF alpha mode.
    @Test
    func testAGLTFShaderMaterialTakesItsRenderQueueFromTheAlphaMode() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let appendedIndex = try document.typed().materials.count
        try document.append(try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url), under: 0)

        let blended = try GLBRewriter.rewritingJSON(of: try document.serialize()) { json in
            var materials = json.objects(.materials)
            materials[appendedIndex]["alphaMode"] = "BLEND"
            json.setObjects(materials, for: .materials)
        }
        let loader = try VRMSceneLoader(withData: blended)

        #expect(try loader.renderQueue(forMaterialAt: appendedIndex) == 3000)
        // The avatar's own materials keep the queue their VRM 0.x entry names.
        #expect(try loader.renderQueue(forMaterialAt: 0) == VRM0(data: VRMSampleAsset.aliciaSolid.data)
            .materialProperties[0].renderQueue)
    }

    /// An `SCNGeometryElement` carries the primitive mode as well as the accessor, so two
    /// primitives sharing one indices accessor each get the mode they were built for.
    @Test
    func testAnIndexAccessorReadAsTwoModesGivesEachItsOwnElement() throws {
        let loader = try VRMSceneLoader(withData: VRMSampleAsset.aliciaSolid.data)
        let indices = try #require(try GLTFDocument(data: VRMSampleAsset.aliciaSolid.data)
            .gltf.meshes.first?.primitives.first?.indices)

        let triangles = try loader.indexAccessor(withAccessorIndex: indices, mode: .TRIANGLES)
        let lines = try loader.indexAccessor(withAccessorIndex: indices, mode: .LINES)

        #expect(triangles.primitiveType == .triangles)
        #expect(lines.primitiveType == .line)
    }

    @Test
    func testNormalizedByteWeightsAreExpandedIntoFloats() throws {
        try expectExpandedWeights(componentType: 5121,
                                  bytes: [255, 128, 0, 0],
                                  expected: [1, 128 / 255, 0, 0])
    }

    @Test
    func testNormalizedShortWeightsAreExpandedIntoFloats() throws {
        try expectExpandedWeights(componentType: 5123,
                                  bytes: [255, 255, 0, 128, 0, 0, 0, 0],
                                  expected: [1, 32768 / 65535, 0, 0])
    }

    /// glTF stores skin weights as floats or normalized integers, and `SCNSkinner` reads
    /// floats, so the integers are expanded into the fractions they stand for.
    private func expectExpandedWeights(componentType: Int,
                                       bytes: [UInt8],
                                       expected: [Float],
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let accessor = try JSONDecoder().decode(
            GLTF.Accessor.self,
            from: Data("""
            {"bufferView": 0, "count": 1, "componentType": \(componentType), "type": "VEC4", "normalized": true}
            """.utf8)
        )
        let packed = try PackedAccessor(accessor: accessor, bufferView: { _ in (Data(bytes), nil) })

        let source = SCNGeometrySource(accessor: packed, semantic: .boneWeights)

        #expect(source.usesFloatComponents, sourceLocation: sourceLocation)
        #expect(source.bytesPerComponent == MemoryLayout<Float>.size, sourceLocation: sourceLocation)
        let weights = source.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(weights.count == expected.count, sourceLocation: sourceLocation)
        for (weight, wanted) in zip(weights, expected) {
            #expect(weight.isApproximatelyEqual(to: wanted), sourceLocation: sourceLocation)
        }
    }

    /// Joint references stay the integers `SCNSkinner` reads them as.
    @Test
    func testJointIndicesStayIntegers() throws {
        let accessor = try JSONDecoder().decode(
            GLTF.Accessor.self,
            from: Data(#"{"bufferView": 0, "count": 1, "componentType": 5121, "type": "VEC4"}"#.utf8)
        )
        let packed = try PackedAccessor(accessor: accessor, bufferView: { _ in (Data([3, 1, 0, 0]), nil) })

        let source = SCNGeometrySource(accessor: packed, semantic: .boneIndices)

        #expect(!source.usesFloatComponents)
        #expect(source.bytesPerComponent == 1)
        #expect(Array(source.data) == [3, 1, 0, 0])
    }

    /// `KHR_texture_transform` moves the UVs a material samples its textures with, which
    /// SceneKit reads off the property's contents transform.
    @Test(arguments: [Float(0), .pi / 2])
    func testTextureTransformReachesTheMaterialProperty(rotation: Float) throws {
        let materialIndex = try #require(try GLTFDocument(data: VRMSampleAsset.aliciaSolid.data)
            .gltf.materials.firstIndex { $0.pbrMetallicRoughness?.baseColorTexture != nil })
        let transformed = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var materials = json.objects(.materials)
            materials[materialIndex].withObject("pbrMetallicRoughness") { pbr in
                pbr.withObject("baseColorTexture") { info in
                    info["extensions"] = ["KHR_texture_transform":
                        ["offset": [0.25, 0.5], "scale": [2, 3], "rotation": .number(rotation)]]
                }
            }
            json.setObjects(materials, for: .materials)
            json["extensionsUsed"] = .strings(json.strings("extensionsUsed") + ["KHR_texture_transform"])
        }

        let loader = try VRMSceneLoader(withData: transformed)
        let contentsTransform = try loader.material(withMaterialIndex: materialIndex).diffuse.contentsTransform

        // The extension composes translation * rotation * scale onto the UV.
        let (sine, cosine) = (sin(rotation), cos(rotation))
        #expect(simd_float4x4(contentsTransform).isApproximatelyEqual(
            to: simd_float4x4(columns: (SIMD4<Float>(2 * cosine, -2 * sine, 0, 0),
                                                                                                  SIMD4<Float>(3 * sine, 3 * cosine, 0, 0),
                                                                                                  SIMD4<Float>(0, 0, 1, 0),
                                                                                                  SIMD4<Float>(0.25, 0.5, 0, 1)))))
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
private extension SCNNode {
    var allDescendants: [SCNNode] {
        childNodes.flatMap { [$0] + $0.allDescendants }
    }

    /// Every primitive drawn below this node, and how many triangle indices each draws.
    var drawnPrimitives: [ObjectIdentifier: Int] {
        allDescendants.reduce(into: [:]) { drawn, node in
            guard !node.isHiddenBelow(self), let count = node.geometry?.triangleIndexCount else { return }
            drawn[ObjectIdentifier(node)] = count
        }
    }

    func isHiddenBelow(_ root: SCNNode) -> Bool {
        var node: SCNNode? = self
        while let current = node, current !== root {
            if current.isHidden { return true }
            node = current.parent
        }
        return false
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
private extension SCNGeometry {
    /// Nil for a geometry drawing no triangles, so a holder is not counted.
    var triangleIndexCount: Int? {
        let triangles = elements.filter { $0.primitiveType == .triangles }
        guard !triangles.isEmpty else { return nil }
        return triangles.reduce(0) { $0 + $1.primitiveCount * 3 }
    }
}
