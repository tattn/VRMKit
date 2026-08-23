import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

@Suite
struct GLTFMergeTests {
    /// The use the whole toolkit is for: resolve a humanoid bone, append a prop
    /// under it, save. Everything the model already had has to come out the
    /// other side untouched, indices included.
    @Test
    func testAppendingUnderAHumanoidBoneKeepsTheModelIntact() throws {
        let vrm = try VRM(data: VRMSampleAsset.aliciaSolid.data)
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let hand = try #require(vrm.nodeIndex(of: .leftHand))
        let before = try document.typed()

        let container = try document.append(try GLTFDocument(withURL: GLTFSampleAsset.boxVertexColors.url),
                                            under: hand,
                                            name: "prop",
                                            transform: GLTFNodeTransform(translation: SIMD3(0, 0.1, 0)))

        let output = try document.serialize()
        let merged = try VRM0(data: output)
        let nodes = try #require(merged.document.gltf.nodes)
        #expect(nodes[hand].children?.contains(container) == true)
        #expect(nodes[container].name == "prop")
        #expect(nodes[container].translation.y == 0.1)
        #expect(nodes[container].children?.count == 1)
        // The model's own nodes stayed where they were, so its humanoid, spring
        // bones and blend shapes still name what they used to.
        #expect(try VRM(data: output).nodeIndex(of: .leftHand) == hand)
        #expect(zip(try #require(before.nodes), nodes).allSatisfy { $0.name == $1.name })
        #expect(nodes.count == (before.nodes?.count ?? 0) + 2)  // the box, plus the container
    }

    /// VRM 0.x reads its material settings out of an array that runs parallel
    /// to `materials`, so appending a material has to extend it too.
    @Test
    func testAppendingToAVRM0KeepsMaterialPropertiesParallel() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url)
        let materialsBefore = try document.typed().materials?.count ?? 0

        try document.append(source, under: 0)

        let merged = try VRM0(data: try document.serialize())
        let materials = try #require(merged.document.gltf.materials)
        #expect(materials.count == materialsBefore + 1)
        #expect(merged.materialProperties.count == materials.count)
        #expect(merged.materialProperties.last?.shader == "VRM_USE_GLTFSHADER")
        #expect(merged.materialProperties.last?.name == materials.last?.name ?? "")
        // The entries the model came with are untouched.
        #expect(merged.materialProperties.dropLast().allSatisfy { $0.shader != "VRM_USE_GLTFSHADER" })
    }

    @Test
    func testAppendingToAVRM1LeavesItsExtensionsAlone() throws {
        let vrm = try VRM(data: VRMSampleAsset.seedSan.data)
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let head = try #require(vrm.nodeIndex(of: .head))

        try document.append(try GLTFDocument(withURL: GLTFSampleAsset.boxVertexColors.url), under: head)

        let output = try document.serialize()
        let merged = try VRM1(data: output)
        #expect(merged.humanoid.humanBones[.head]?.node == head)
        let originalExtensions = try GLTFDocument(data: VRMSampleAsset.seedSan.data).rawJSON()["extensions"]
        let mergedExtensions = try GLTFDocument(data: output).rawJSON()["extensions"]
        #expect(jsonDifference(try #require(originalExtensions), try #require(mergedExtensions)) == nil)
    }

    /// Meshes, skins and animations name each other by index, so a merge that
    /// rebases one wrongly comes apart in a way only the data shows.
    @Test
    func testAppendedSkinAndAnimationKeepTheirData() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.simpleSkin.url)
        let before = try document.typed()
        let nodeBase = before.nodes?.count ?? 0
        let accessorBase = before.accessors?.count ?? 0
        let meshBase = before.meshes?.count ?? 0

        let container = try document.append(source, under: 0, name: "skinned")

        let merged = try GLTFDocument(data: try document.serialize())
        let sourceSkin = try #require(source.gltf.skins?.first)
        let mergedSkin = try #require(merged.gltf.skins?.last)
        #expect(mergedSkin.joints == sourceSkin.joints.map { $0 + nodeBase })
        #expect(mergedSkin.inverseBindMatrices == sourceSkin.inverseBindMatrices.map { $0 + accessorBase })

        let sourceChannel = try #require(source.gltf.animations?.first?.channels.first)
        let mergedChannel = try #require(merged.gltf.animations?.last?.channels.first)
        #expect(mergedChannel.target.node == sourceChannel.target.node.map { $0 + nodeBase })
        let sourceSampler = try #require(source.gltf.animations?.first?.samplers.first)
        let mergedSampler = try #require(merged.gltf.animations?.last?.samplers.first)
        #expect(mergedSampler.input == sourceSampler.input + accessorBase)
        #expect(mergedSampler.output == sourceSampler.output + accessorBase)

        // The mesh that came over reads back the same vertices it had, out of
        // the four buffers the source spread them across.
        let sourcePrimitive = try #require(source.gltf.meshes?.first?.primitives.first)
        let mergedPrimitive = try #require(merged.gltf.meshes?[meshBase].primitives.first)
        for (attribute, index) in sourcePrimitive.attributes.rawValue {
            #expect(mergedPrimitive.attributes.rawValue[attribute] == index + accessorBase)
        }
        try expectSameAccessors(source, merged,
                                offset: accessorBase,
                                indices: Array(sourcePrimitive.attributes.rawValue.values))
        #expect(try #require(merged.gltf.nodes)[container].children?.count == 2)
    }

    /// A GLB has nowhere to keep a texture but inside itself, so an image the
    /// source left in a file of its own is read into the buffer.
    @Test
    func testAppendedImagesAreEmbeddedInTheBuffer() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url)
        let before = try document.typed()
        let imageBase = before.images?.count ?? 0
        let textureBase = before.textures?.count ?? 0
        let samplerBase = before.samplers?.count ?? 0

        try document.append(source, under: 0)

        let merged = try GLTFDocument(data: try document.serialize())
        let image = try #require(merged.gltf.images?[imageBase])
        #expect(image.uri == nil)
        #expect(image.mimeType == "image/png")
        let expected = try Data(contentsOf: GLTFSampleAsset.simpleTexture.rootDirectory
            .appendingPathComponent("testTexture.png"))
        #expect(try merged.bufferViewData(at: try #require(image.bufferView)).data == expected)

        let texture = try #require(merged.gltf.textures?[textureBase])
        #expect(texture.source == imageBase)
        #expect(texture.sampler == samplerBase)
        let material = try #require(merged.gltf.materials?.last)
        #expect(material.pbrMetallicRoughness?.baseColorTexture?.index == textureBase)
    }

    /// Every buffer view has to start on a 4 byte boundary, whatever length the
    /// buffers being concatenated happen to have.
    @Test
    func testAppendingOddlySizedBuffersKeepsTheAlignment() throws {
        let source = """
        {
            "asset": {"version": "2.0"},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [{"name": "odd"}],
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQ=", "byteLength": 5},
                        {"uri": "data:application/octet-stream;base64,BQYH", "byteLength": 3}],
            "bufferViews": [{"buffer": 0, "byteLength": 5}, {"buffer": 1, "byteLength": 3}]
        }
        """
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)

        for _ in 0..<3 {
            try document.append(try GLTFDocument(data: Data(source.utf8)), under: 0)
        }

        let merged = try GLTFDocument(data: try document.serialize())
        // The model's own views are left exactly where they were, including
        // the unaligned ones its exporter wrote for images.
        let views = try #require(merged.gltf.bufferViews)
        let appended = views.indices.suffix(6)
        #expect(appended.allSatisfy { views[$0].byteOffset % 4 == 0 })
        for (offset, index) in appended.enumerated() {
            let expected = offset.isMultiple(of: 2) ? Data([0, 1, 2, 3, 4]) : Data([5, 6, 7])
            #expect(try merged.bufferViewData(at: index).data == expected)
        }
    }

    @Test
    func testAppendingACompressedSourceFails() throws {
        let draco = try GLTFSampleAsset.triangle.rewritingJSON {
            $0["extensionsRequired"] = ["KHR_draco_mesh_compression"]
            $0["extensionsUsed"] = ["KHR_draco_mesh_compression"]
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: draco, rootDirectory: GLTFSampleAsset.triangle.rootDirectory)

        #expect(throws: VRMError.self) { try document.append(source, under: 0) }
    }

    @Test
    func testAppendingASourceWithUnrebasableRootExtensionsFails() throws {
        let lit = try GLTFSampleAsset.triangle.rewritingJSON {
            $0["extensions"] = ["KHR_lights_punctual": ["lights": [["type": "point"]]]]
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: lit, rootDirectory: GLTFSampleAsset.triangle.rootDirectory)

        #expect(throws: VRMError.self) { try document.append(source, under: 0) }
    }

    /// A merge rebases indices, and an extension it has never heard of may
    /// hold some, so what may be merged is an allowlist.
    @Test
    func testAppendingASourceUsingAnUnknownExtensionFails() throws {
        let unknown = try GLTFSampleAsset.triangle.rewritingJSON {
            $0["extensionsUsed"] = ["EXT_something_nobody_here_has_read"]
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: unknown, rootDirectory: GLTFSampleAsset.triangle.rootDirectory)

        #expect(throws: VRMError.self) { try document.append(source, under: 0) }
    }

    /// A key ending in `Texture` outside the slots glTF defines is the
    /// document's own field, so rewriting its `index` would change what the
    /// merge promises to carry over untouched.
    @Test
    func testAppendingLeavesMaterialExtrasAlone() throws {
        let withExtras = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            var materials = json["materials"] as? [[String: Any]] ?? []
            materials[0]["extras"] = ["previewTexture": ["index": 0]]
            json["materials"] = materials
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: withExtras, rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory)
        let texturesBefore = try document.typed().textures?.count ?? 0

        try document.append(source, under: 0)

        let material = try #require(try GLTFDocument(data: try document.serialize()).rawJSON().objects(.materials).last)
        #expect(material.object("extras")?.object("previewTexture")?.index("index") == 0)
        // The material's own texture reference did move, so the merge is
        // rebasing where it should and nowhere else.
        let baseColor = material.object("pbrMetallicRoughness")?.object("baseColorTexture")
        #expect(baseColor?.index("index") == texturesBefore)
    }

    /// A material extension the source never declared slips past the list of
    /// what a merge may carry, so the materials are checked as well.
    @Test
    func testAppendingASourceWithAnUndeclaredMaterialExtensionFails() throws {
        let unknown = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            var materials = json["materials"] as? [[String: Any]] ?? []
            materials[0]["extensions"] = ["ACME_materials_glitter": ["glitterTexture": ["index": 0]]]
            json["materials"] = materials
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: unknown, rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory)

        #expect(throws: VRMError.self) { try document.append(source, under: 0) }
    }

    /// An extension the source could not be rendered without stays one the
    /// merged document cannot be either.
    @Test
    func testAppendingCarriesOverWhatTheSourceRequires() throws {
        let unlit = try GLTFSampleAsset.triangle.rewritingJSON {
            $0["extensionsUsed"] = ["KHR_materials_unlit"]
            $0["extensionsRequired"] = ["KHR_materials_unlit"]
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: unlit, rootDirectory: GLTFSampleAsset.triangle.rootDirectory)

        try document.append(source, under: 0)

        let merged = try GLTFDocument(data: try document.serialize()).rawJSON()
        #expect(merged.strings("extensionsUsed").contains("KHR_materials_unlit"))
        #expect(merged.strings("extensionsRequired").contains("KHR_materials_unlit"))
    }

    @Test
    func testAppendingUnderAMissingNodeChangesNothing() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.serialize()

        #expect(throws: VRMError.self) {
            try document.append(try GLTFDocument(withURL: GLTFSampleAsset.triangle.url), under: 100_000)
        }
        #expect(try document.serialize() == before)
    }

    /// A source holding several scenes and naming none says nothing about
    /// which to take, so it has to be told which.
    @Test
    func testAppendingASourceThatNamesNoSceneAmongSeveralFails() throws {
        let ambiguous = try GLTFSampleAsset.triangle.rewritingJSON { json in
            json[.scenes] = json.objects(.scenes) + [["nodes": []]]
            json.removeValue(forKey: "scene")
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: ambiguous, rootDirectory: GLTFSampleAsset.triangle.rootDirectory)

        #expect(throws: VRMError.self) { try document.append(source, under: 0) }
        // Naming it is all it takes.
        #expect(throws: Never.self) { try document.append(source, sceneAt: 0, under: 0) }
    }

    @Test
    func testAppendingASceneOutOfRangeFails() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.triangle.url)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.append(source, sceneAt: 7, under: 0) }
        #expect(try document.serialize() == before)
    }

    /// A VRM 0.x model keeps a material's MToon settings in its root
    /// extension, so copying its nodes alone would strip their shading.
    @Test
    func testAppendingAVRM0SourceFails() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let source = try GLTFDocument(data: VRMSampleAsset.aliciaSolid.data)

        #expect(throws: VRMError.self) { try document.append(source, under: 0) }
    }

    /// A VRM 1.0 model describes its materials on the materials themselves, so
    /// only what makes it an avatar is dropped and the props keep their look.
    @Test
    func testAppendingAVRM1SourceKeepsItsMToonMaterials() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: VRMSampleAsset.seedSan.data)
        let materialsBefore = try document.typed().materials?.count ?? 0

        try document.append(source, under: 0)

        let merged = try GLTFDocument(data: try document.serialize())
        let appended = try #require(merged.gltf.materials?.dropFirst(materialsBefore))
        #expect(!appended.isEmpty)
        #expect(appended.contains { $0.extensions?.materialsMToon != nil })
    }

    /// Reading the source's resources can fail once the merge is writing, and
    /// an append either lands whole or not at all.
    @Test
    func testAppendingASourceWithAMissingImageChangesNothing() throws {
        let broken = try GLTFSampleAsset.simpleTexture.rewritingJSON {
            $0[.images] = [["uri": "there-is-no-such-file.png"]]
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.serialize()
        let source = try GLTFDocument(data: broken,
                                      rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory)

        #expect(throws: (any Error).self) { try document.append(source, under: 0) }
        #expect(try document.serialize() == before)
    }

    /// glTF has a document declare every extension it uses, so one it carries
    /// without declaring is read off the document itself rather than trusted:
    /// its indices would come over pointing into the source's own arrays.
    @Test
    func testAppendingASourceWithAnUndeclaredNestedExtensionFails() throws {
        let undeclared = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            json.mapObjects(.meshes) { mesh in
                var mesh = mesh
                mesh.mapObjects("primitives") { primitive in
                    var primitive = primitive
                    primitive["extensions"] = ["KHR_draco_mesh_compression": ["bufferView": 0]] as JSONObject
                    return primitive
                }
                return mesh
            }
        }
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: undeclared,
                                      rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory)

        #expect(throws: VRMError.self) { try document.append(source, under: 0) }
    }
}
