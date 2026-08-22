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
    func testGenericLoadBuildsEntityGraphWithNodeMapping() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withData: TestSupport.seedSanData)
        let entity = try loader.loadEntity()

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

    @Test
    func testGenericLoadSetsUpSkinBindingsWithInitialPose() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try GLTFEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        #expect(!entity.skinBindings.isEmpty)
        for binding in entity.skinBindings {
            #expect(binding.modelEntity.components.has(SkeletalPosesComponent.self))
            #expect(!binding.jointEntities.isEmpty)
        }
    }

    /// Meshes are built once and cloned per node, skinned ones included, so a
    /// second scene off the same loader reuses the `MeshResource` while binding
    /// its own joint entities.
    @Test
    func testReloadingASceneReusesItsMeshesAndBindsItsOwnJoints() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func root(of entity: Entity) -> Entity {
            var root = entity
            while let parent = root.parent { root = parent }
            return root
        }
        let loader = try GLTFEntityLoader(withData: TestSupport.seedSanData)
        let first = try loader.loadEntity()
        let second = try loader.loadEntity()

        #expect(!second.skinBindings.isEmpty)
        #expect(first.skinBindings.count == second.skinBindings.count)
        for (old, new) in zip(first.skinBindings, second.skinBindings) {
            #expect(old.modelEntity !== new.modelEntity)
            #expect(old.modelEntity.model?.mesh === new.modelEntity.model?.mesh)
            #expect(new.jointEntities.allSatisfy { root(of: $0) === second })
        }
    }

    @Test
    func testGenericLoadRecordsMorphBindings() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try GLTFEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        #expect(!entity.morphBindings.isEmpty)
        for (nodeIndex, binding) in entity.morphBindings {
            #expect(entity.entity(forNodeAt: nodeIndex) != nil)
            for modelEntity in binding.modelEntities {
                #expect(modelEntity.components.has(BlendShapeWeightsComponent.self))
            }
        }
    }

    @Test
    func testInitialMorphWeightsComeFromNodeThenMesh() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Find a node whose mesh has morph targets, then give that node
        // explicit starting weights.
        let document = try GLTFLoader().load(withData: TestSupport.seedSanData)
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
            guard var nodes = json["nodes"] as? [[String: Any]] else {
                throw VRMError.dataInconsistent("missing nodes")
            }
            nodes[nodeIndex]["weights"] = weights
            json["nodes"] = nodes
        }

        let entity = try GLTFEntityLoader(withData: modified).loadEntity()
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
    func testMorphWeightsOfTheWrongLengthFailTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let gltf = try GLTFLoader().load(withData: TestSupport.seedSanData).gltf
        let (nodeIndex, meshIndex, targetCount) = try #require(
            gltf.nodes?.enumerated().compactMap { index, node -> (Int, Int, Int)? in
                guard let meshIndex = node.mesh,
                      let targets = gltf.meshes?[meshIndex].primitives.first?.targets,
                      !targets.isEmpty else { return nil }
                return (index, meshIndex, targets.count)
            }.first)

        func weighted(_ count: Int, key: String, of collection: String, at index: Int) throws -> Data {
            try TestSupport.modifiedSeedSanData(name: "\(collection) \(count) weights") { json in
                guard var elements = json[collection] as? [[String: Any]] else {
                    throw VRMError.dataInconsistent("missing \(collection)")
                }
                elements[index][key] = [Double](repeating: 0.5, count: count)
                json[collection] = elements
            }
        }

        let shortNodeWeights = try weighted(targetCount - 1, key: "weights", of: "nodes", at: nodeIndex)
        #expect(throws: VRMError.self) { try GLTFEntityLoader(withData: shortNodeWeights).loadEntity() }

        let longMeshWeights = try weighted(targetCount + 1, key: "weights", of: "meshes", at: meshIndex)
        #expect(throws: VRMError.self) { try GLTFEntityLoader(withData: longMeshWeights).loadEntity() }

        // The same rewrite with the right length still loads.
        let exact = try weighted(targetCount, key: "weights", of: "nodes", at: nodeIndex)
        #expect(try GLTFEntityLoader(withData: exact).loadEntity().morphBindings[nodeIndex] != nil)
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
    func testUnsupportedRequiredExtensionFailsGenericLoadButNotVRM() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanData(name: "unsupported required extension") { json in
            json["extensionsRequired"] = ["FAKE_required_extension"]
        }

        #expect(throws: VRMError.self) {
            _ = try GLTFEntityLoader(withData: modified).loadEntity()
        }
        // The VRM path only warns about an unimplemented required extension.
        _ = try VRMEntityLoader(withData: modified).loadEntity()
    }

    /// Hand-written because every glTF-Sample-Assets model with a sparse accessor
    /// is CC-BY-4.0, which the test assets avoid.
    @Test
    func testSparseAccessorSubstitutesPositions() throws {
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

        let entity = try GLTFEntityLoader(withData: Data(json.utf8)).loadEntity()
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
    func testMaterialSamplingUVSet1SelectsTEXCOORD1() throws {
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

        let entity = try GLTFEntityLoader(withData: Data(json.utf8)).loadEntity()
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
    func testMetallicRoughnessTextureKeepsItsFactors() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.simpleTexture) { json in
            guard var materials = json["materials"] as? [[String: Any]] else { return }
            materials[0]["pbrMetallicRoughness"] = [
                "baseColorTexture": ["index": 0],
                "metallicRoughnessTexture": ["index": 0],
                "metallicFactor": 0.25,
                "roughnessFactor": 0.75
            ]
            json["materials"] = materials
        }
        _ = try loader.loadEntity()

        let material = try #require(try loader.material(withMaterialIndex: 0) as? PhysicallyBasedMaterial)
        #expect(material.metallic.texture != nil)
        #expect(material.roughness.texture != nil)
        #expect(material.metallic.scale.isApproximatelyEqual(to: 0.25))
        #expect(material.roughness.scale.isApproximatelyEqual(to: 0.75))
    }

    /// A primitive without a material renders with glTF's default material: a lit
    /// white PBR one, not an unlit fill.
    @Test
    func testPrimitiveWithoutAMaterialRendersAsLitPBR() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try TestSupport.loadEntity(.triangle)

        let model = try #require(entity.modelEntitiesInHierarchy.first?.components[ModelComponent.self])
        let material = try #require(model.materials.first as? PhysicallyBasedMaterial)
        #expect(material.metallic.scale.isApproximatelyEqual(to: 1))
        #expect(material.roughness.scale.isApproximatelyEqual(to: 1))
    }

    /// RealityKit meshes render triangles only, so a POINTS or LINES primitive is
    /// skipped: the node it hangs on still loads, it just draws nothing.
    @Test
    func testNonTriangledPrimitivesAreSkippedWithoutFailingTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for mode in [0, 1, 2, 3] {  // POINTS, LINES, LINE_LOOP, LINE_STRIP
            let loader = try TestSupport.loader(.triangle) { json in
                guard var meshes = json["meshes"] as? [[String: Any]],
                      var primitives = meshes.first?["primitives"] as? [[String: Any]] else {
                    throw VRMError.dataInconsistent("Missing Triangle fixture primitives")
                }
                primitives[0]["mode"] = mode
                meshes[0]["primitives"] = primitives
                json["meshes"] = meshes
            }
            let entity = try loader.loadEntity()

            #expect(entity.modelEntitiesInHierarchy.isEmpty)
            #expect(entity.entity(forNodeAt: 0) != nil)
        }
        // The same fixture with its TRIANGLES mode intact does render.
        #expect(try !TestSupport.loadEntity(.triangle).modelEntitiesInHierarchy.isEmpty)
    }

    /// glTF leaves `scene` out for assets that are a library of nodes, which the
    /// generic loader must not silently render as scene 0.
    @Test
    func testLoadingAnAssetWithoutADefaultSceneNeedsAnExplicitIndex() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.triangle) { json in
            json.removeValue(forKey: "scene")
        }

        #expect(loader.document.gltf.scene == nil)
        #expect(throws: VRMError.self) { try loader.loadEntity() }
        #expect(throws: Never.self) { try loader.loadEntity(withSceneIndex: 0) }
    }

    /// A VRM is a single avatar, so its loader still renders one without a
    /// default scene.
    @Test
    func testVRMWithoutADefaultSceneStillLoads() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "no default scene") { json in
            json.removeValue(forKey: "scene")
        }
        let entity = try VRMEntityLoader(withData: data).loadEntity()

        #expect(entity.sceneIndex == 0)
    }

    /// glTF node hierarchies are forests. A cyclic one would recurse forever, so
    /// it has to fail the load instead.
    @Test
    func testCyclicNodeHierarchyFailsTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.triangle) { json in
            json["nodes"] = [["children": [1]], ["children": [0]]]
            json["scenes"] = [["nodes": [0]]]
        }

        #expect(throws: VRMError.self) { try loader.loadEntity() }
    }

    /// A node reached from two parents is neither renderable as a tree nor valid
    /// glTF.
    @Test
    func testNodeWithTwoParentsFailsTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.triangle) { json in
            json["nodes"] = [["children": [2]], ["children": [2]], ["mesh": 0]]
            json["scenes"] = [["nodes": [0, 1]]]
        }

        #expect(throws: VRMError.self) { try loader.loadEntity() }
    }

    /// `scene.nodes` names root nodes. Attaching one that already has a parent
    /// would reparent it, so the resulting hierarchy would depend on the order
    /// `scene.nodes` happens to list them in.
    @Test
    func testSceneRootThatIsAlreadyAChildFailsTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try TestSupport.loader(.triangle) { json in
            json["nodes"] = [["children": [1]], ["mesh": 0]]
            json["scenes"] = [["nodes": [0, 1]]]
        }

        #expect(throws: VRMError.self) { try loader.loadEntity() }
    }

    /// RealityKit gives a material one UV transform, so an asset that *requires*
    /// `KHR_texture_transform` and gives a material's textures different ones is
    /// asking for a render this loader cannot produce. One shared transform stays
    /// within what it implements.
    @Test
    func testRequiredTextureTransformBeyondOnePerMaterialFailsTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func loader(emissiveScale: [Double]) throws -> GLTFEntityLoader {
            try TestSupport.loader(.simpleTexture) { json in
                let transform: (String, Any) -> [String: Any] = { key, scale in
                    ["index": 0, "extensions": ["KHR_texture_transform": [key: scale]]]
                }
                json["extensionsUsed"] = ["KHR_texture_transform"]
                json["extensionsRequired"] = ["KHR_texture_transform"]
                json["materials"] = [[
                    "pbrMetallicRoughness": ["baseColorTexture": transform("scale", [2.0, 2.0])],
                    "emissiveTexture": transform("scale", emissiveScale)
                ]]
            }
        }

        _ = try loader(emissiveScale: [2.0, 2.0]).loadEntity()
        #expect(throws: VRMError.self) { try loader(emissiveScale: [3.0, 3.0]).loadEntity() }
    }

    /// `KHR_texture_transform` overrides the UV set a texture samples, and a mesh
    /// carries one UV channel, so an asset that *requires* the extension while
    /// pointing a material's textures at different sets is asking for a render
    /// this loader cannot produce, however its transforms agree.
    @Test
    func testRequiredTextureTransformBeyondOneUVSetPerMaterialFailsTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func loader(emissiveTexCoord: Int) throws -> GLTFEntityLoader {
            try TestSupport.loader(.simpleTexture) { json in
                let texture: (Int) -> [String: Any] = { texCoord in
                    ["index": 0, "extensions": ["KHR_texture_transform": ["texCoord": texCoord]]]
                }
                json["extensionsUsed"] = ["KHR_texture_transform"]
                json["extensionsRequired"] = ["KHR_texture_transform"]
                json["materials"] = [[
                    "pbrMetallicRoughness": ["baseColorTexture": texture(0)],
                    "emissiveTexture": texture(emissiveTexCoord)
                ]]
            }
        }

        _ = try loader(emissiveTexCoord: 0).loadEntity()
        #expect(throws: VRMError.self) { try loader(emissiveTexCoord: 1).loadEntity() }
    }

    /// Skin joints index the joint arrays positionally, so a repeated, missing or
    /// out-of-range joint has to throw rather than trap.
    @Test
    func testMalformedSkinJointsFailTheLoad() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for joints in [[1, 1], [], [99]] {
            let loader = try TestSupport.loader(.simpleSkin) { json in
                guard var skins = json["skins"] as? [[String: Any]] else { return }
                skins[0]["joints"] = joints
                skins[0].removeValue(forKey: "inverseBindMatrices")
                json["skins"] = skins
            }
            #expect(throws: VRMError.self, "joints \(joints) must not load") {
                try loader.loadEntity()
            }
        }
    }

    /// A clone shares the meshes and the document but not the bindings the
    /// animation runtime drives, so playback has to report that instead of
    /// silently doing nothing.
    @Test
    func testAnimatingACloneIsRejected() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try TestSupport.loadEntity(.animatedTriangle)
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
    func testAnimationSamplerReadingAnAccessorAsTheWrongTypeFails() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // The input accessor is SCALAR; a rotation output has to be VEC4.
        let entity = try TestSupport.loader(.animatedTriangle) { json in
            guard var animations = json["animations"] as? [[String: Any]],
                  var samplers = animations[0]["samplers"] as? [[String: Any]] else { return }
            samplers[0]["output"] = samplers[0]["input"]
            animations[0]["samplers"] = samplers
            json["animations"] = animations
        }.loadEntity()

        #expect(throws: VRMError.self) { try entity.playAnimation(at: 0) }
    }

    /// VRM meshes split by indices share one POSITION accessor and put the morph
    /// targets on a single primitive; the VRM loader shares them across the rest,
    /// which the plain glTF loader must not do.
    @Test
    func testVRMSharesMorphTargetsAcrossPrimitivesButPlainGLTFDoesNot() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func morphableModelCount(_ entity: Entity) -> Int {
            entity.modelEntitiesInHierarchy.filter { $0.components.has(BlendShapeWeightsComponent.self) }.count
        }
        // AliciaSolid names no default scene, so the plain loader is given one.
        let vrm = try VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let plain = try GLTFEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity(withSceneIndex: 0)

        #expect(morphableModelCount(vrm) > morphableModelCount(plain))
    }

    /// A degenerate triangle in a primitive without NORMAL keeps the zero normal
    /// `flatNormals()` leaves it, and the tangent basis a normal map then asks
    /// for must not turn that into NaN.
    @Test
    func testDegenerateTriangleUnderANormalMapKeepsTheTangentBasisFinite() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // The fixture's index buffer lives in its .bin, so the degenerate
        // triangle arrives through a buffer of its own.
        var degenerateIndices = Data()
        degenerateIndices.appendLittleEndian([0, 0, 1, 0, 1, 2])
        let loader = try TestSupport.loader(.simpleTexture) { json in
            guard var buffers = json["buffers"] as? [[String: Any]],
                  var bufferViews = json["bufferViews"] as? [[String: Any]],
                  var accessors = json["accessors"] as? [[String: Any]],
                  var materials = json["materials"] as? [[String: Any]] else {
                throw VRMError.dataInconsistent("unexpected SimpleTexture layout")
            }
            buffers.append([
                "uri": "data:application/octet-stream;base64,\(degenerateIndices.base64EncodedString())",
                "byteLength": degenerateIndices.count
            ])
            bufferViews.append(["buffer": buffers.count - 1, "byteOffset": 0, "byteLength": degenerateIndices.count])
            accessors[0]["bufferView"] = bufferViews.count - 1
            materials[0]["normalTexture"] = ["index": 0]
            json["buffers"] = buffers
            json["bufferViews"] = bufferViews
            json["accessors"] = accessors
            json["materials"] = materials
        }

        let entity = try loader.loadEntity()
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
    func testPrimitiveWithoutNORMALIsFlatShaded() throws {
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

        let entity = try GLTFEntityLoader(withData: Data(json.utf8)).loadEntity()
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
    func testVRM0BlendShapeOnAnUnskinnedMeshDrivesTheSceneEntity() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // AliciaSolid's blend-shape meshes are skinned, so one is unskinned here
        // to reach the clone path.
        let modified = try TestSupport.modifiedAliciaSolidData(name: "unskinned blend shape mesh") { json in
            guard let vrm = (json["extensions"] as? [String: Any])?["VRM"] as? [String: Any],
                  let master = vrm["blendShapeMaster"] as? [String: Any],
                  let groups = master["blendShapeGroups"] as? [[String: Any]],
                  let bind = groups.lazy.compactMap({ ($0["binds"] as? [[String: Any]])?.first }).first,
                  let meshIndex = bind["mesh"] as? Int,
                  var nodes = json["nodes"] as? [[String: Any]] else {
                throw VRMError.dataInconsistent("Missing AliciaSolid blend shape fixture data")
            }
            for index in nodes.indices where nodes[index]["mesh"] as? Int == meshIndex {
                nodes[index]["skin"] = nil
            }
            json["nodes"] = nodes
        }

        let vrmEntity = try VRMEntityLoader(withData: modified, shaders: TestSupport.noOutlineShaders).loadEntity()
        let clip = try #require(vrmEntity.blendShapeClips.values.first { clip in
            clip.values.contains { $0.weight > 0 }
        })
        let binding = try #require(clip.values.first { $0.weight > 0 })
        // The bind resolved to an entity of the scene, not to a clone template.
        #expect(TestSupport.isDescendant(binding.mesh, of: vrmEntity))

        vrmEntity.setBlendShape(value: 1, for: clip.key)
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
    func testVRMEntityIsAGLTFEntity() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        // The VRM runtime sits on the generic one: document, node mapping and skin
        // bindings all come from the base.
        let base: GLTFEntity = vrmEntity
        #expect(base.sceneIndex == base.gltf.scene)
        #expect(!base.skinBindings.isEmpty)
        #expect(base.entity(forNodeAt: 0) != nil)
    }
}
#endif
