#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Loads the VRM fixtures through the generic glTF loader: a VRM file is a GLB
/// with extensions, so it doubles as a plain glTF fixture.
@Suite
@MainActor
struct GLTFEntityLoaderTests {
    @Test
    func testGenericLoadBuildsEntityGraphWithNodeMapping() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withData: TestSupport.seedSanData)
        let entity = try await loader.loadEntity()

        #expect(!(entity is VRMEntity))
        #expect(entity.sceneIndex == entity.gltf.scene)
        #expect(entity.document.gltf.nodes?.isEmpty == false)

        // Every scene node resolves through the index mapping.
        let nodeCount = entity.gltf.nodes?.count ?? 0
        var mappedCount = 0
        for index in 0..<nodeCount {
            guard let node = entity.entity(forNodeAt: index) else { continue }
            mappedCount += 1
            #expect(node.components[GLTFNodeComponent.self]?.nodeIndex == index)
        }
        #expect(mappedCount > 0)
        #expect(entity.entity(forNodeAt: nodeCount) == nil)
        #expect(entity.entity(forNodeAt: -1) == nil)
    }

    /// Authoring names the scene it makes as the document's default, which is
    /// the one `loadEntity()` asks a glTF for.
    @Test
    func testAnAuthoredDocumentLoadsThroughItsDefaultScene() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        var document = GLTFEditableDocument()
        let mesh = GLTFTriangleMesh(positions: [SIMD3(-0.5, -0.5, 0), SIMD3(0.5, -0.5, 0), SIMD3(0, 0.5, 0)],
                                    indices: [0, 1, 2])
        let nodeIndex = try document.addMesh(mesh, name: "plate")

        let entity = try await GLTFEntityLoader(withData: try document.serialize()).loadEntity()

        #expect(entity.sceneIndex == 0)
        #expect(entity.entity(forNodeAt: nodeIndex.rawValue)?.name == "plate")
    }

    @Test
    func testGenericLoadSetsUpSkinBindingsWithInitialPose() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        #expect(!entity.skinBindings.isEmpty)
        for binding in entity.skinBindings {
            #expect(binding.modelEntity.components.has(SkeletalPosesComponent.self))
            #expect(!binding.jointEntities.isEmpty)
        }
    }

    /// A second scene off the same loader reuses the `MeshResource` while binding
    /// its own joint entities.
    @Test
    func testReloadingASceneReusesItsMeshesAndBindsItsOwnJoints() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func root(of entity: Entity) -> Entity {
            var root = entity
            while let parent = root.parent { root = parent }
            return root
        }
        let loader = try GLTFEntityLoader(withData: TestSupport.seedSanData)
        let first = try await loader.loadEntity()
        let second = try await loader.loadEntity()

        #expect(!second.skinBindings.isEmpty)
        #expect(first.skinBindings.count == second.skinBindings.count)
        for (old, new) in zip(first.skinBindings, second.skinBindings) {
            #expect(old.modelEntity !== new.modelEntity)
            #expect(old.modelEntity.model?.mesh === new.modelEntity.model?.mesh)
            #expect(new.jointEntities.allSatisfy { root(of: $0) === second })
        }
    }

    @Test
    func testGenericLoadRecordsMorphBindings() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await GLTFEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        #expect(!entity.morphBindings.isEmpty)
        for (nodeIndex, binding) in entity.morphBindings {
            #expect(entity.entity(forNodeAt: nodeIndex) != nil)
            for modelEntity in binding.modelEntities {
                #expect(modelEntity.components.has(BlendShapeWeightsComponent.self))
            }
        }
    }

    @Test
    func testInitialMorphWeightsComeFromNodeThenMesh() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Find a node whose mesh has morph targets, then give that node
        // explicit starting weights.
        let document = try GLTFDocument(data: TestSupport.seedSanData)
        let gltf = document.gltf
        let (nodeIndex, targetCount) = try #require(gltf.nodes?.enumerated().compactMap { index, node -> (Int, Int)? in
            guard let meshIndex = node.mesh,
                  let targets = gltf.meshes?[meshIndex].primitives.first?.targets,
                  !targets.isEmpty else { return nil }
            return (index, targets.count)
        }.first)

        var weights = [Double](repeating: 0, count: targetCount)
        weights[0] = 0.5
        let modified = try TestSupport.modifiedSeedSanData(name: "node initial weights") { json in
            var nodes = json.objects("nodes")
            guard nodes.indices.contains(nodeIndex) else {
                throw VRMError.dataInconsistent("missing nodes")
            }
            nodes[nodeIndex]["weights"] = .array(weights.map(JSONValue.double))
            json["nodes"] = .objects(nodes)
        }

        let entity = try await GLTFEntityLoader(withData: modified).loadEntity()
        let binding = try #require(entity.morphBindings[nodeIndex])
        #expect(binding.targetCount == targetCount)
        let applied = binding.modelEntities.contains { modelEntity in
            modelEntity.blendWeights.contains { set in
                set.first.map { abs($0 - 0.5) < 0.0001 } ?? false
            }
        }
        #expect(applied)
    }

    /// glTF sizes `node.weights` and `mesh.weights` by the mesh's morph target
    /// count; a different length is not a partial pose to apply as far as it goes.
    @Test
    func testMorphWeightsOfTheWrongLengthFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let gltf = try GLTFDocument(data: TestSupport.seedSanData).gltf
        let (nodeIndex, meshIndex, targetCount) = try #require(
            gltf.nodes?.enumerated().compactMap { index, node -> (Int, Int, Int)? in
                guard let meshIndex = node.mesh,
                      let targets = gltf.meshes?[meshIndex].primitives.first?.targets,
                      !targets.isEmpty else { return nil }
                return (index, meshIndex, targets.count)
            }.first)

        func weighted(_ count: Int, key: String, of collection: String, at index: Int) throws -> Data {
            try TestSupport.modifiedSeedSanData(name: "\(collection) \(count) weights") { json in
                var elements = json.objects(collection)
                guard elements.indices.contains(index) else {
                    throw VRMError.dataInconsistent("missing \(collection)")
                }
                elements[index][key] = .array([JSONValue](repeating: .double(0.5), count: count))
                json[collection] = .objects(elements)
            }
        }

        let shortNodeWeights = try weighted(targetCount - 1, key: "weights", of: "nodes", at: nodeIndex)
        await #expect(throws: VRMError.self) { try await GLTFEntityLoader(withData: shortNodeWeights).loadEntity() }

        let longMeshWeights = try weighted(targetCount + 1, key: "weights", of: "meshes", at: meshIndex)
        await #expect(throws: VRMError.self) { try await GLTFEntityLoader(withData: longMeshWeights).loadEntity() }

        // The same rewrite with the right length still loads.
        let exact = try weighted(targetCount, key: "weights", of: "nodes", at: nodeIndex)
        #expect(try await GLTFEntityLoader(withData: exact).loadEntity().morphBindings[nodeIndex] != nil)
    }

    @Test
    func testGenericLoadRendersMToonFromGLTFExtension() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
#if !os(visionOS)
        // Seed-san's materials carry VRMC_materials_mtoon as a plain glTF
        // material extension, so the generic loader renders them as MToon too.
        let loader = try GLTFEntityLoader(withData: TestSupport.seedSanData)
        let material = try loader.material(withMaterialIndex: 0)
        #expect(material is CustomMaterial, TestSupport.expectedCustomMaterialMessage)
#endif
    }

    @Test
    func testUnsupportedRequiredExtensionFailsGenericLoadButNotVRM() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "unsupported required extension") { json in
            json["extensionsRequired"] = ["FAKE_required_extension"]
        }

        await #expect(throws: VRMError.self) {
            _ = try await GLTFEntityLoader(withData: modified).loadEntity()
        }
        // The VRM path only warns about an unimplemented required extension.
        _ = try await VRMEntityLoader(withData: modified).loadEntity()
    }

    /// Hand-written because every glTF-Sample-Assets model with a sparse accessor
    /// is CC-BY-4.0, which the test assets avoid.
    @Test
    func testSparseAccessorSubstitutesPositions() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // A triangle whose third vertex is (0, 1, 0) in the base buffer and is
        // replaced by (0, 5, 0) through the accessor's sparse substitution.
        var buffer = Data()
        let indicesOffset = buffer.count
        buffer.appendLittleEndian([0, 1, 2])
        buffer.append(contentsOf: [0, 0]) // pad to a 4 byte boundary
        let positionsOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0, 0, 0, 1, 0, 0, 0, 1, 0]))
        let sparseIndicesOffset = buffer.count
        buffer.appendLittleEndian([2])
        buffer.append(contentsOf: [0, 0])
        let sparseValuesOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0, 5, 0]))

        let json = """
        {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": 1}, "indices": 0}]}],
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": \(indicesOffset), "byteLength": 6},
                {"buffer": 0, "byteOffset": \(positionsOffset), "byteLength": 36},
                {"buffer": 0, "byteOffset": \(sparseIndicesOffset), "byteLength": 2},
                {"buffer": 0, "byteOffset": \(sparseValuesOffset), "byteLength": 12}
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5123, "count": 3, "type": "SCALAR"},
                {
                    "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3",
                    "min": [0, 0, 0], "max": [1, 5, 0],
                    "sparse": {
                        "count": 1,
                        "indices": {"bufferView": 2, "componentType": 5123},
                        "values": {"bufferView": 3}
                    }
                }
            ]
        }
        """

        let entity = try await GLTFEntityLoader(withData: Data(json.utf8)).loadEntity()
        let model = try #require(entity.modelEntitiesInHierarchy.first?.components[ModelComponent.self])
        let positions = try #require(model.mesh.contents.models.first?.parts.first?.positions.elements)

        #expect(positions.count == 3)
        #expect(positions[2].isApproximatelyEqual(to: SIMD3<Float>(0, 5, 0)))
        // The untouched vertices keep their base-buffer values.
        #expect(positions[1].isApproximatelyEqual(to: SIMD3<Float>(1, 0, 0)))
    }

    /// A material whose textures sample UV set 1 gets TEXCOORD_1 as the mesh's
    /// single RealityKit UV channel. Hand-written: MultiUVTest is CC-BY-4.0.
    @Test
    func testMaterialSamplingUVSet1SelectsTEXCOORD1() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        var buffer = Data(littleEndianFloats: [0, 0, 0, 1, 0, 0, 0, 1, 0])  // POSITION
        let uv0Offset = buffer.count
        buffer.append(Data(littleEndianFloats: [0, 0, 0, 0, 0, 0]))         // TEXCOORD_0
        let uv1Offset = buffer.count
        buffer.append(Data(littleEndianFloats: [0.25, 0.75, 0.5, 0.75, 0.25, 0.5]))  // TEXCOORD_1
        let whitePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC"

        let json = """
        {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{
                "attributes": {"POSITION": 0, "TEXCOORD_0": 1, "TEXCOORD_1": 2},
                "material": 0
            }]}],
            "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0, "texCoord": 1}}}],
            "textures": [{"source": 0}],
            "images": [{"uri": "data:image/png;base64,\(whitePixelPNG)"}],
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": 36},
                {"buffer": 0, "byteOffset": \(uv0Offset), "byteLength": 24},
                {"buffer": 0, "byteOffset": \(uv1Offset), "byteLength": 24}
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
                {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2"},
                {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"}
            ]
        }
        """

        let entity = try await GLTFEntityLoader(withData: Data(json.utf8)).loadEntity()
        let model = try #require(entity.modelEntitiesInHierarchy.first?.components[ModelComponent.self])
        let uvs = try #require(model.mesh.contents.models.first?.parts.first?.textureCoordinates?.elements)

        #expect(uvs.count == 3)
        // The loader flips V (RealityKit's UV origin is bottom-left), so the
        // TEXCOORD_1 values arrive as (u, 1 - v).
        #expect(uvs[0].isApproximatelyEqual(to: SIMD2<Float>(0.25, 0.25)))
        #expect(uvs[1].isApproximatelyEqual(to: SIMD2<Float>(0.5, 0.25)))
        #expect(uvs[2].isApproximatelyEqual(to: SIMD2<Float>(0.25, 0.5)))
    }

    /// glTF's final metallic / roughness is the sampled texture channel times the
    /// factor, so a texture must not drop the factors on the floor.
    @Test
    func testMetallicRoughnessTextureKeepsItsFactors() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.simpleTexture) { json in
            var materials = json.objects("materials")
            guard !materials.isEmpty else { return }
            materials[0]["pbrMetallicRoughness"] = [
                "baseColorTexture": ["index": 0],
                "metallicRoughnessTexture": ["index": 0],
                "metallicFactor": 0.25,
                "roughnessFactor": 0.75
            ]
            json["materials"] = .objects(materials)
        }
        _ = try await loader.loadEntity()

        let material = try #require(try loader.material(withMaterialIndex: 0) as? PhysicallyBasedMaterial)
        #expect(material.metallic.texture != nil)
        #expect(material.roughness.texture != nil)
        #expect(material.metallic.scale.isApproximatelyEqual(to: 0.25))
        #expect(material.roughness.scale.isApproximatelyEqual(to: 0.75))
    }

    /// A primitive without a material renders with glTF's default material: a lit
    /// white PBR one, not an unlit fill.
    @Test
    func testPrimitiveWithoutAMaterialRendersAsLitPBR() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.triangle)

        let model = try #require(entity.modelEntitiesInHierarchy.first?.components[ModelComponent.self])
        let material = try #require(model.materials.first as? PhysicallyBasedMaterial)
        #expect(material.metallic.scale.isApproximatelyEqual(to: 1))
        #expect(material.roughness.scale.isApproximatelyEqual(to: 1))
    }

    /// RealityKit meshes render triangles only, so a POINTS or LINES primitive is
    /// skipped: the node it hangs on still loads, it just draws nothing.
    @Test
    func testNonTriangledPrimitivesAreSkippedWithoutFailingTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for mode in [0, 1, 2, 3] {  // POINTS, LINES, LINE_LOOP, LINE_STRIP
            let loader = try TestSupport.loader(.triangle) { json in
                var meshes = json.objects("meshes")
                var primitives = meshes.first?.objects("primitives") ?? []
                guard !primitives.isEmpty else {
                    throw VRMError.dataInconsistent("Missing Triangle fixture primitives")
                }
                primitives[0]["mode"] = .int(mode)
                meshes[0]["primitives"] = .objects(primitives)
                json["meshes"] = .objects(meshes)
            }
            let entity = try await loader.loadEntity()

            #expect(entity.modelEntitiesInHierarchy.isEmpty)
            #expect(entity.entity(forNodeAt: 0) != nil)
        }
        // The same fixture with its TRIANGLES mode intact does render.
        await #expect(try !TestSupport.loadEntity(.triangle).modelEntitiesInHierarchy.isEmpty)
    }

    /// A glTF texture is an image plus a sampler, and only the image decides the
    /// decoded resource, so two textures over one image share one.
    @Test
    func testTexturesOverOneImageShareTheDecodedResource() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "second sampler") { json in
            var duplicate = json.objects("textures")[0]
            duplicate["sampler"] = .int(json.count("samplers"))
            json["samplers"] = .objects(json.objects("samplers") + [["wrapS": .int(33071)]])
            json["textures"] = .objects(json.objects("textures") + [duplicate])
        }

        let loader = try GLTFEntityLoader(withData: data)
        let duplicate = (loader.document.gltf.textures?.count ?? 0) - 1
        #expect(try loader.texture(withTextureIndex: 0) === loader.texture(withTextureIndex: duplicate))
        #expect(try loader.sampler(withTextureIndex: 0) != loader.sampler(withTextureIndex: duplicate))
    }

    /// An asset of one scene has no default to name, but one holding several and
    /// naming none says nothing about which to draw.
    @Test
    func testLoadingAnAssetWithoutADefaultSceneNeedsAnExplicitIndex() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let single = try TestSupport.loader(.triangle) { json in
            json.removeValue(forKey: "scene")
        }
        #expect(single.document.gltf.scene == nil)
        await #expect(throws: Never.self) { try await single.loadEntity() }

        let several = try TestSupport.loader(.triangle) { json in
            json.removeValue(forKey: "scene")
            json["scenes"] = .objects(json.objects("scenes") + [[:]])
        }
        await #expect(throws: VRMError.self) { try await several.loadEntity() }
        await #expect(throws: Never.self) { try await several.loadEntity(withSceneIndex: 0) }
    }

    /// A VRM is a single avatar, so it renders without naming a default scene.
    @Test
    func testVRMWithoutADefaultSceneStillLoads() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "no default scene") { json in
            json.removeValue(forKey: "scene")
        }
        let entity = try await VRMEntityLoader(withData: data).loadEntity()

        #expect(entity.sceneIndex == 0)
    }

    /// A node states its transform as TRS or as a 16-value column-major
    /// `matrix`, and one carrying the matrix places its mesh from it.
    @Test
    func testNodeMatrixIsReadAsItsLocalTransform() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loader(.triangle) { json in
            json["nodes"] = [["mesh": 0, "matrix": [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 1, 2, 3, 1]]]
        }.loadEntity()

        let node = try #require(entity.entity(forNodeAt: 0))
        #expect(node.transform.translation.isApproximatelyEqual(to: SIMD3<Float>(1, 2, 3)))
        #expect(node.transform.scale.isApproximatelyEqual(to: SIMD3<Float>(2, 2, 2)))

        // A matrix of any other length fails the parse, before the load.
        #expect(throws: VRMError.self) {
            try TestSupport.loader(.triangle) { json in
                json["nodes"] = [["mesh": 0, "matrix": [1, 0, 0, 0]]]
            }
        }
    }

    /// glTF node hierarchies are forests. A cyclic one would recurse forever, so
    /// it has to fail the load instead.
    @Test
    func testCyclicNodeHierarchyFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.triangle) { json in
            json["nodes"] = [["children": [1]], ["children": [0]]]
            json["scenes"] = [["nodes": [0]]]
        }

        await #expect(throws: VRMError.self) { try await loader.loadEntity() }
    }

    /// A node reached from two parents is neither renderable as a tree nor valid
    /// glTF.
    @Test
    func testNodeWithTwoParentsFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.triangle) { json in
            json["nodes"] = [["children": [2]], ["children": [2]], ["mesh": 0]]
            json["scenes"] = [["nodes": [0, 1]]]
        }

        await #expect(throws: VRMError.self) { try await loader.loadEntity() }
    }

    /// `scene.nodes` names root nodes. Attaching one that already has a parent
    /// would reparent it, so the resulting hierarchy would depend on the order
    /// `scene.nodes` happens to list them in.
    @Test
    func testSceneRootThatIsAlreadyAChildFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.triangle) { json in
            json["nodes"] = [["children": [1]], ["mesh": 0]]
            json["scenes"] = [["nodes": [0, 1]]]
        }

        await #expect(throws: VRMError.self) { try await loader.loadEntity() }
    }

    /// RealityKit gives a material one UV transform, so an asset requiring
    /// `KHR_texture_transform` with differing per-texture transforms asks for a
    /// render this loader cannot produce.
    @Test
    func testRequiredTextureTransformBeyondOnePerMaterialFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func loader(emissiveScale: [Double]) throws -> GLTFEntityLoader {
            try TestSupport.loader(.simpleTexture) { json in
                let transform: (String, [Double]) -> JSONValue = { key, scale in
                    ["index": 0, "extensions": ["KHR_texture_transform": [key: .array(scale.map(JSONValue.double))]]]
                }
                json["extensionsUsed"] = ["KHR_texture_transform"]
                json["extensionsRequired"] = ["KHR_texture_transform"]
                json["materials"] = [[
                    "pbrMetallicRoughness": ["baseColorTexture": transform("scale", [2.0, 2.0])],
                    "emissiveTexture": transform("scale", emissiveScale)
                ]]
            }
        }

        _ = try await loader(emissiveScale: [2.0, 2.0]).loadEntity()
        await #expect(throws: VRMError.self) { try await loader(emissiveScale: [3.0, 3.0]).loadEntity() }
    }

    /// A mesh carries one UV channel, so an asset requiring
    /// `KHR_texture_transform` while pointing a material's textures at different
    /// UV sets asks for a render this loader cannot produce.
    @Test
    func testRequiredTextureTransformBeyondOneUVSetPerMaterialFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func loader(emissiveTexCoord: Int) throws -> GLTFEntityLoader {
            try TestSupport.loader(.simpleTexture) { json in
                let texture: (Int) -> JSONValue = { texCoord in
                    ["index": 0, "extensions": ["KHR_texture_transform": ["texCoord": .int(texCoord)]]]
                }
                json["extensionsUsed"] = ["KHR_texture_transform"]
                json["extensionsRequired"] = ["KHR_texture_transform"]
                json["materials"] = [[
                    "pbrMetallicRoughness": ["baseColorTexture": texture(0)],
                    "emissiveTexture": texture(emissiveTexCoord)
                ]]
            }
        }

        _ = try await loader(emissiveTexCoord: 0).loadEntity()
        await #expect(throws: VRMError.self) { try await loader(emissiveTexCoord: 1).loadEntity() }
    }

    /// Skin joints index the joint arrays positionally, so a repeated, missing or
    /// out-of-range joint has to throw rather than trap.
    @Test
    func testMalformedSkinJointsFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for joints in [[1, 1], [], [99]] {
            let loader = try TestSupport.loader(.simpleSkin) { json in
                var skins = json.objects("skins")
                guard !skins.isEmpty else { return }
                skins[0]["joints"] = .numbers(joints)
                skins[0].removeValue(forKey: "inverseBindMatrices")
                json["skins"] = .objects(skins)
            }
            await #expect(throws: VRMError.self, "joints \(joints) must not load") {
                try await loader.loadEntity()
            }
        }
    }

    /// A clone carries no animation bindings, so playback has to report that
    /// instead of silently doing nothing.
    @Test
    func testAnimatingACloneIsRejected() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.animatedTriangle)
        let clone = entity.clone(recursive: true)

        #expect(entity.hasRuntimeBindings)
        #expect(!clone.hasRuntimeBindings)
        // The metadata still reads off the document it carries.
        #expect(clone.animations.count == entity.animations.count)
        #expect(throws: VRMError.self) { try clone.playAnimation(at: 0) }
    }

    /// An animation sampler that reads a shared accessor as the wrong type must
    /// fail even when the accessor is already in the decoder's cache.
    @Test
    func testAnimationSamplerReadingAnAccessorAsTheWrongTypeFails() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // The input accessor is SCALAR; a rotation output has to be VEC4.
        let entity = try await TestSupport.loader(.animatedTriangle) { json in
            var animations = json.objects("animations")
            guard !animations.isEmpty else { return }
            var samplers = animations[0].objects("samplers")
            guard !samplers.isEmpty else { return }
            samplers[0]["output"] = samplers[0]["input"]
            animations[0]["samplers"] = .objects(samplers)
            json["animations"] = .objects(animations)
        }.loadEntity()

        #expect(throws: VRMError.self) { try entity.playAnimation(at: 0) }
    }

    /// VRM meshes put the morph targets on a single primitive and the VRM loader
    /// shares them across the rest, which the plain glTF loader must not do.
    @Test
    func testVRMSharesMorphTargetsAcrossPrimitivesButPlainGLTFDoesNot() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func morphableModelCount(_ entity: Entity) -> Int {
            entity.modelEntitiesInHierarchy.filter { $0.components.has(BlendShapeWeightsComponent.self) }.count
        }
        // AliciaSolid names no default scene, so the plain loader is given one.
        let vrm = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let plain = try await GLTFEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity(withSceneIndex: 0)

        #expect(morphableModelCount(vrm) > morphableModelCount(plain))
    }

    /// A degenerate triangle keeps the zero normal `flatNormals()` leaves it, and
    /// the tangent basis a normal map asks for must not turn that into NaN.
    @Test
    func testDegenerateTriangleUnderANormalMapKeepsTheTangentBasisFinite() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // The fixture's index buffer lives in its .bin, so the degenerate
        // triangle arrives through a buffer of its own.
        var degenerateIndices = Data()
        degenerateIndices.appendLittleEndian([0, 0, 1, 0, 1, 2])
        let loader = try TestSupport.loader(.simpleTexture) { json in
            var buffers = json.objects("buffers")
            var bufferViews = json.objects("bufferViews")
            var accessors = json.objects("accessors")
            var materials = json.objects("materials")
            guard !buffers.isEmpty, !bufferViews.isEmpty, !accessors.isEmpty, !materials.isEmpty else {
                throw VRMError.dataInconsistent("unexpected SimpleTexture layout")
            }
            buffers.append([
                "uri": .string("data:application/octet-stream;base64,\(degenerateIndices.base64EncodedString())"),
                "byteLength": .int(degenerateIndices.count)
            ])
            bufferViews.append([
                "buffer": .int(buffers.count - 1),
                "byteOffset": 0,
                "byteLength": .int(degenerateIndices.count)
            ])
            accessors[0]["bufferView"] = .int(bufferViews.count - 1)
            materials[0]["normalTexture"] = ["index": 0]
            json["buffers"] = .objects(buffers)
            json["bufferViews"] = .objects(bufferViews)
            json["accessors"] = .objects(accessors)
            json["materials"] = .objects(materials)
        }

        let entity = try await loader.loadEntity()
        let model = try #require(entity.modelEntitiesInHierarchy.first?.components[ModelComponent.self])
        let part = try #require(model.mesh.contents.models.first?.parts.first)
        let tangents = try #require(part.tangents?.elements)
        let bitangents = try #require(part.bitangents?.elements)

        #expect(tangents.count == 6)
        #expect(tangents.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        #expect(bitangents.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    /// glTF flat shades a primitive that ships no NORMAL, so the shared vertices
    /// of two folded triangles must not average into one smooth normal.
    @Test
    func testPrimitiveWithoutNORMALIsFlatShaded() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Two triangles sharing the edge (0,0,0)-(1,0,0): one in the z = 0 plane
        // facing +z, one in the y = 0 plane facing +y.
        var buffer = Data()
        let indicesOffset = buffer.count
        buffer.appendLittleEndian([0, 1, 2, 0, 3, 1])
        let positionsOffset = buffer.count
        buffer.append(Data(littleEndianFloats: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]))

        let json = """
        {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": 1}, "indices": 0}]}],
            "buffers": [{"uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())", "byteLength": \(buffer.count)}],
            "bufferViews": [
                {"buffer": 0, "byteOffset": \(indicesOffset), "byteLength": 12},
                {"buffer": 0, "byteOffset": \(positionsOffset), "byteLength": 48}
            ],
            "accessors": [
                {"bufferView": 0, "componentType": 5123, "count": 6, "type": "SCALAR"},
                {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 1]}
            ]
        }
        """

        let entity = try await GLTFEntityLoader(withData: Data(json.utf8)).loadEntity()
        let model = try #require(entity.modelEntitiesInHierarchy.first?.components[ModelComponent.self])
        let part = try #require(model.mesh.contents.models.first?.parts.first)
        let normals = try #require(part.normals?.elements)

        // Flat shading needs a vertex per triangle corner.
        #expect(part.positions.elements.count == 6)
        #expect(normals.count == 6)
        for normal in normals[0..<3] {
            #expect(normal.isApproximatelyEqual(to: SIMD3<Float>(0, 0, 1)))
        }
        for normal in normals[3..<6] {
            #expect(normal.isApproximatelyEqual(to: SIMD3<Float>(0, 1, 0)))
        }
    }

    /// RealityKit's normal parameter has no scale beside its texture, so
    /// `normalTexture.scale` is baked into the map: x and y scale, then the
    /// vector is renormalized.
    @Test
    func testNormalTextureScaleIsBakedIntoTheMap() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withData: GLTFSampleAsset.triangle.data,
                                          rootDirectory: GLTFSampleAsset.triangle.rootDirectory)
        // (0, 0, 1) straight up, and a normal tilted 45° toward +x.
        let source = try Self.image(rgb: [[128, 128, 255], [218, 128, 218]])

        let unchanged = try Self.pixels(of: loader.scaledNormalImage(source, scale: 1))
        #expect(unchanged[0] == [128, 128, 255])
        #expect(unchanged[1] == [218, 128, 218])

        let flattened = try Self.pixels(of: loader.scaledNormalImage(source, scale: 0))
        // With nothing left of x and y, every texel is the neutral normal.
        #expect(flattened[0] == [128, 128, 255])
        #expect(flattened[1] == [128, 128, 255])

        // Half the tilt: x drops from 0.71 to 0.45 once renormalized.
        let halved = try Self.pixels(of: loader.scaledNormalImage(source, scale: 0.5))
        #expect(halved[0] == [128, 128, 255])
        #expect(halved[1] == [185, 128, 242])
    }

    /// `occlusionTexture.strength` blends the sampled occlusion toward "no
    /// occlusion", which RealityKit's ambient occlusion parameter cannot express
    /// on its own either.
    @Test
    func testOcclusionTextureStrengthIsBakedIntoTheMap() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withData: GLTFSampleAsset.triangle.data,
                                          rootDirectory: GLTFSampleAsset.triangle.rootDirectory)
        // Fully occluded, half occluded and unoccluded texels.
        let source = try Self.image(rgb: [[0, 0, 0], [128, 0, 0], [255, 0, 0]])

        let unchanged = try Self.pixels(of: loader.weakenedOcclusionImage(source, strength: 1))
        #expect(unchanged.map(\.first) == [0, 128, 255])

        let halved = try Self.pixels(of: loader.weakenedOcclusionImage(source, strength: 0.5))
        #expect(halved.map(\.first) == [128, 192, 255])

        let disabled = try Self.pixels(of: loader.weakenedOcclusionImage(source, strength: 0))
        #expect(disabled.map(\.first) == [255, 255, 255])
    }

    /// A row of 8-bit RGB texels as a `CGImage`.
    private static func image(rgb: [[UInt8]]) throws -> CGImage {
        let bytes: [UInt8] = rgb.flatMap { $0 + [255] }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: rgb.count,
                                    height: 1,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: rgb.count * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent))
    }

    /// The image's texels as `[r, g, b]` rows.
    private static func pixels(of image: CGImage) throws -> [[UInt8]] {
        var bytes = [UInt8](repeating: 0, count: image.width * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(data: raw.baseAddress,
                                                 width: image.width,
                                                 height: 1,
                                                 bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: 1))
        }
        return (0..<image.width).map { Array(bytes[$0 * 4 ..< $0 * 4 + 3]) }
    }

    /// Only the clones of an unskinned mesh join the scene, so a VRM 0.x
    /// blend-shape bind has to drive those, not the template they came from.
    @Test
    func testVRM0BlendShapeOnAnUnskinnedMeshDrivesTheSceneEntity() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // AliciaSolid's blend-shape meshes are skinned, so one is unskinned here
        // to reach the clone path.
        let modified = try TestSupport.modifiedAliciaSolidData(name: "unskinned blend shape mesh") { json in
            guard let vrm = json.object("extensions")?.object("VRM"),
                  let master = vrm.object("blendShapeMaster") else {
                throw VRMError.dataInconsistent("Missing AliciaSolid blend shape fixture data")
            }
            let groups = master.objects("blendShapeGroups")
            guard let bind = groups.lazy.compactMap({ $0.objects("binds").first }).first,
                  let meshIndex = bind.int("mesh") else {
                throw VRMError.dataInconsistent("Missing AliciaSolid blend shape fixture data")
            }
            var nodes = json.objects("nodes")
            for index in nodes.indices where nodes[index].int("mesh") == meshIndex {
                nodes[index]["skin"] = nil
            }
            json["nodes"] = .objects(nodes)
        }

        let vrmEntity = try await VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()
        let clip = try #require(vrmEntity.expressionClips.values.first { clip in
            clip.values.contains { $0.weight > 0 }
        })
        let binding = try #require(clip.values.first { $0.weight > 0 })
        // The bind resolved to an entity of the scene, not to a clone template.
        #expect(TestSupport.isDescendant(binding.mesh, of: vrmEntity))

        vrmEntity.setExpression(value: 1, for: clip.key)
        let targetName = "blendShape_\(binding.index)"
        let applied = TestSupport.modelEntities(in: vrmEntity).contains { modelEntity in
            let weights = modelEntity.blendWeights
            let names = modelEntity.blendWeightNames
            return names.indices.contains { setIndex in
                guard setIndex < weights.count,
                      let nameIndex = names[setIndex].firstIndex(of: targetName),
                      nameIndex < weights[setIndex].count else { return false }
                return weights[setIndex][nameIndex] > 0
            }
        }
        #expect(applied)
    }

    @Test
    func testVRMEntityIsAGLTFEntity() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        // The VRM runtime sits on the generic one: document, node mapping and skin
        // bindings all come from the base.
        let base: GLTFEntity = vrmEntity
        #expect(base.sceneIndex == base.gltf.scene)
        #expect(!base.skinBindings.isEmpty)
        #expect(base.entity(forNodeAt: 0) != nil)
    }
}
#endif
