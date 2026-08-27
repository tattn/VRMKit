import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

/// Building a glTF out of vertex data rather than reading one from a file.
@Suite
struct GLTFAuthoringTests {
    // MARK: - Round trip

    /// What `addMesh` writes has to read back as what it was given, through
    /// the loader any other asset goes through.
    @Test
    func testAuthoredMeshRoundTripsThroughAGLB() throws {
        var document = GLTFEditableDocument()

        let nodeIndex = try document.addMesh(.plate(material: .picture),
                                         name: "plate",
                                         transform: GLTFNodeTransform(translation: SIMD3(0, 1, 0)))

        let saved = try GLTFDocument(data: try document.serialize())
        let gltf = saved.gltf
        #expect(gltf.asset.version == "2.0")
        // The scene the document was given, named as the one it draws.
        #expect(gltf.scene == 0)
        let scene = try #require(gltf.scenes?[0])
        #expect(scene.nodes == [nodeIndex.rawValue])
        let node = try #require(gltf.nodes?[nodeIndex.rawValue])
        #expect(node.name == "plate")
        #expect(node.translation == SIMD3(0, 1, 0))

        let primitive = try saved.primitive(onNodeAt: nodeIndex.rawValue)
        #expect(primitive.mode == .TRIANGLES)
        #expect(primitive.material == 0)
        let mesh = GLTFTriangleMesh.plate(material: nil)
        #expect(try saved.vector3Attribute(.POSITION, of: primitive) == mesh.positions)
        #expect(try saved.vector3Attribute(.NORMAL, of: primitive) == mesh.normals)
        #expect(try saved.textureCoordinates(of: primitive) == mesh.textureCoordinates)
        #expect(try saved.indices(of: primitive) == mesh.indices)
    }

    // MARK: - Sampler

    @Test
    func testSamplerIsWrittenAsTheMaterialDescribedIt() throws {
        var document = GLTFEditableDocument()
        var material = GLTFSimpleMaterial.picture
        material.baseColorSampler = GLTFTextureSampler(wrapS: .CLAMP_TO_EDGE,
                                                       wrapT: .MIRRORED_REPEAT,
                                                       magFilter: .NEAREST,
                                                       minFilter: .LINEAR_MIPMAP_LINEAR)

        let nodeIndex = try document.addMesh(.plate(material: material))

        let saved = try GLTFDocument(data: try document.serialize())
        let materialIndex = try #require(saved.primitive(onNodeAt: nodeIndex.rawValue).material)
        let written = try #require(saved.gltf.materials?[materialIndex])
        let textureIndex = try #require(written.pbrMetallicRoughness?.baseColorTexture?.index)
        let samplerIndex = try #require(saved.gltf.textures?[textureIndex].sampler)
        let sampler = try #require(saved.gltf.samplers?[samplerIndex])
        #expect(sampler.wrapS == .CLAMP_TO_EDGE)
        #expect(sampler.wrapT == .MIRRORED_REPEAT)
        #expect(sampler.magFilter == .NEAREST)
        #expect(sampler.minFilter == .LINEAR_MIPMAP_LINEAR)
    }

    /// A texture naming no sampler already repeats and filters as the reader
    /// likes, so a sampler asking for that is not written.
    @Test
    func testASamplerAtItsDefaultsIsNotWritten() throws {
        var document = GLTFEditableDocument()

        let nodeIndex = try document.addMesh(.plate(material: .picture))

        let saved = try GLTFDocument(data: try document.serialize())
        let materialIndex = try #require(saved.primitive(onNodeAt: nodeIndex.rawValue).material)
        let written = try #require(saved.gltf.materials?[materialIndex])
        let textureIndex = try #require(written.pbrMetallicRoughness?.baseColorTexture?.index)
        #expect(saved.gltf.textures?[textureIndex].sampler == nil)
        #expect(saved.gltf.samplers == nil)
    }

    /// A sampler naming only a filter leaves the wrapping unwritten.
    @Test
    func testOnlyTheSamplerFieldsAskedForAreWritten() throws {
        var document = GLTFEditableDocument()
        var material = GLTFSimpleMaterial.picture
        material.baseColorSampler = GLTFTextureSampler(magFilter: .NEAREST)

        try document.addMesh(.plate(material: material))

        let json = try #require(try JSONValue(parsing: JSONValue.object(document.json).serialized()).objectValue)
        let sampler = try #require(json.objects(.samplers).first)
        #expect(sampler.count == 1)
        #expect(sampler.index("magFilter") == GLTF.Sampler.MagFilter.NEAREST.rawValue)
    }

    /// glTF requires the bounds of a position accessor, and a plate's four
    /// corners are what they are computed from.
    @Test
    func testPositionAccessorCarriesTheBoundsGLTFRequires() throws {
        var document = GLTFEditableDocument()

        let nodeIndex = try document.addMesh(.plate(material: nil))

        let saved = try GLTFDocument(data: try document.serialize())
        let primitive = try saved.primitive(onNodeAt: nodeIndex.rawValue)
        let index = try #require(primitive.attributes[.POSITION])
        let accessor = try #require(saved.gltf.accessors?[index])
        #expect(accessor.min == [-0.5, -0.5, 0])
        #expect(accessor.max == [0.5, 0.5, 0])
    }

    /// Four vertices cost half as much indexed as shorts.
    @Test
    func testSmallMeshesAreIndexedAsUnsignedShorts() throws {
        var document = GLTFEditableDocument()

        let nodeIndex = try document.addMesh(.plate(material: nil))

        let saved = try GLTFDocument(data: try document.serialize())
        let primitive = try saved.primitive(onNodeAt: nodeIndex.rawValue)
        let index = try #require(primitive.indices)
        let accessor = try #require(saved.gltf.accessors?[index])
        #expect(accessor.componentType == .unsignedShort)
    }

    @Test
    func testMaterialIsWrittenAsTheMeshDescribedIt() throws {
        var document = GLTFEditableDocument()
        var material = GLTFSimpleMaterial.picture
        material.alphaMode = .mask(cutoff: 0.25)

        let nodeIndex = try document.addMesh(.plate(material: material))

        let saved = try GLTFDocument(data: try document.serialize())
        let materialIndex = try #require(saved.primitive(onNodeAt: nodeIndex.rawValue).material)
        let written = try #require(saved.gltf.materials?[materialIndex])
        #expect(written.name == "picture")
        #expect(written.pbrMetallicRoughness?.baseColorFactor == SIMD4(1, 0.5, 0.25, 1))
        #expect(written.pbrMetallicRoughness?.metallicFactor == 0)
        #expect(written.alphaMode == .MASK)
        #expect(written.alphaCutoff == 0.25)
        #expect(written.doubleSided)
        #expect(written.extensions?.materialsUnlit != nil)
        #expect(saved.gltf.extensionsUsed?.contains("KHR_materials_unlit") == true)

        // The image is in the buffer, which is the only place a GLB has for it.
        let textureIndex = try #require(written.pbrMetallicRoughness?.baseColorTexture?.index)
        let source = try #require(saved.gltf.textures?[textureIndex].source)
        let image = try #require(saved.gltf.images?[source])
        #expect(image.uri == nil)
        #expect(image.mimeType == "image/png")
        let view = try #require(image.bufferView)
        #expect(try saved.bufferViewData(at: view).data == GLTFSimpleMaterial.pngBytes)
    }

    @Test
    func testAMeshWithoutAMaterialAddsNone() throws {
        var document = GLTFEditableDocument()

        let nodeIndex = try document.addMesh(.plate(material: nil))

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(saved.gltf.materials == nil)
        #expect(try saved.primitive(onNodeAt: nodeIndex.rawValue).material == nil)
    }

    /// `materials: .mtoon` is the same choice `append` offers, so a plate added
    /// to a toon-shaded model is shaded like it.
    @Test
    func testAMeshAddedAsMToonCarriesTheMToonExtension() throws {
        var document = GLTFEditableDocument()

        let nodeIndex = try document.addMesh(.plate(material: .picture), materials: .mtoon)

        let saved = try GLTFDocument(data: try document.serialize())
        let materialIndex = try #require(saved.primitive(onNodeAt: nodeIndex.rawValue).material)
        let material = try #require(saved.gltf.materials?[materialIndex])
        #expect(material.extensions?.materialsMToon != nil)
        #expect(saved.gltf.extensionsUsed?.contains("VRMC_materials_mtoon") == true)
    }

    // MARK: - Placement

    @Test
    func testAMeshHangsUnderTheNodeItWasGiven() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let nodesBefore = try #require(try document.typed().nodes)

        let nodeIndex = try document.addMesh(.plate(material: nil), under: 0, name: "held")

        let nodes = try #require(try document.typed().nodes)
        #expect(nodeIndex.rawValue == nodesBefore.count)
        #expect(nodes[0].children?.contains(nodeIndex.rawValue) == true)
        // Nothing that was there moved, so the VRM extensions still name it.
        #expect(zip(nodesBefore, nodes).allSatisfy { $0.name == $1.name })
    }

    @Test
    func testAddingAMeshUnderAMissingNodeChangesNothing() throws {
        var document = GLTFEditableDocument()
        let before = try document.serialize()

        #expect(throws: VRMError.self) {
            try document.addMesh(.plate(material: .picture), under: 7)
        }

        #expect(try document.serialize() == before)
    }

    // MARK: - Composition

    /// Authoring and merging meet: what was built here is a source `append`
    /// takes like any other document.
    @Test
    func testAnAuthoredDocumentCanBeAppendedIntoAnother() throws {
        var authored = GLTFEditableDocument()
        try authored.addMesh(.plate(material: .picture), name: "plate")
        var target = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let materialsBefore = try target.typed().materials?.count ?? 0

        let container = try target.append(try GLTFDocument(data: try authored.serialize()),
                                          under: 0,
                                          name: "item")

        let merged = try GLTFDocument(data: try target.serialize())
        let nodes = try #require(merged.gltf.nodes)
        #expect(nodes[container.rawValue].name == "item")
        let plate = try #require(nodes[container.rawValue].children?.first)
        #expect(nodes[plate].name == "plate")
        let primitive = try merged.primitive(onNodeAt: plate)
        #expect(try merged.vector3Attribute(.POSITION, of: primitive)
                == GLTFTriangleMesh.plate(material: nil).positions)
        // The plate's material came over after the model's own.
        #expect(primitive.material == materialsBefore)
    }

    // MARK: - VRM consistency

    /// VRM 0.x describes its materials in an array parallel to `materials`, so
    /// a material added to one needs an entry to keep the two lined up.
    @Test
    func testAddingAMeshToAVRM0KeepsItsMaterialPropertiesParallel() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let materialsBefore = try document.typed().materials?.count ?? 0

        let nodeIndex = try document.addMesh(.plate(material: .picture), under: 0)

        let saved = try VRM0(data: try document.serialize())
        #expect(try saved.document.primitive(onNodeAt: nodeIndex.rawValue).material == materialsBefore)
        let materials = try #require(saved.document.gltf.materials)
        #expect(materials.count == materialsBefore + 1)
        #expect(saved.materialProperties.count == materials.count)
        #expect(saved.materialProperties.last?.vrmShader == .gltfShader)
        #expect(saved.materialProperties.last?.name == "picture")
        // The entries the model came with are untouched.
        #expect(saved.materialProperties.dropLast().allSatisfy { $0.vrmShader != .gltfShader })
    }

    /// A document that is not a VRM 0.x model has no such array, and adding a
    /// mesh may not invent one.
    @Test
    func testAddingAMeshToAVRM1AddsNoMaterialProperties() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)

        try document.addMesh(.plate(material: .picture), under: 0)

        #expect(document.vrm0MaterialProperties() == nil)
    }

    // MARK: - Alignment

    /// Every buffer view starts on a four byte boundary, whatever length the
    /// image or the index data appended before it happened to have.
    @Test
    func testOddlySizedDataKeepsTheBufferViewsAligned() throws {
        var document = GLTFEditableDocument()
        // Nine bytes of image and a triangle's three shorts both leave the
        // buffer needing padding.
        let images = (0..<3).map { GLTFSimpleMaterial.pngBytes + Data([UInt8($0)]) }
        for image in images {
            var material = GLTFSimpleMaterial.picture
            material.baseColorImage = image
            try document.addMesh(GLTFTriangleMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                                  textureCoordinates: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
                                                  indices: [0, 1, 2],
                                                  material: material))
        }

        let saved = try GLTFDocument(data: try document.serialize())
        let views = try #require(saved.gltf.bufferViews)
        // An image, positions, texture coordinates and indices, three times.
        #expect(views.count == 12)
        #expect(views.allSatisfy { $0.byteOffset % 4 == 0 })
        // The padding lies between the views rather than inside them, so each
        // still reads back exactly the bytes it was given.
        let written = try #require(saved.gltf.images)
        #expect(written.count == 3)
        for (image, expected) in zip(written, images) {
            let view = try #require(image.bufferView)
            #expect(try saved.bufferViewData(at: view).data == expected)
        }
    }

    // MARK: - Failed edits

    /// Placement is resolved before any resource is written, so an edit that
    /// cannot place its node leaves the document as it was.
    @Test
    func testAMeshThatCannotBePlacedLeavesTheDocumentWritable() throws {
        // Two scenes and no default one, so there is no unambiguous root scene.
        let json = #"{"asset": {"version": "2.0"}, "scenes": [{"nodes": []}, {"nodes": []}], "nodes": [{"name": "a"}]}"#
        var document = try GLTFEditableDocument(data: Data(json.utf8))

        #expect(throws: VRMError.self) { try document.addMesh(.plate(material: .picture)) }
        #expect(try document.typed().images == nil)

        // The same mesh again, this time somewhere it can go.
        let nodeIndex = try document.addMesh(.plate(material: .picture), under: 0)

        let saved = try GLTFDocument(data: try document.serialize())
        let images = try #require(saved.gltf.images)
        #expect(images.count == 1)
        let materialIndex = try #require(saved.primitive(onNodeAt: nodeIndex.rawValue).material)
        let material = try #require(saved.gltf.materials?[materialIndex])
        let textureIndex = try #require(material.pbrMetallicRoughness?.baseColorTexture?.index)
        let source = try #require(saved.gltf.textures?[textureIndex].source)
        let view = try #require(images[source].bufferView)
        #expect(try saved.bufferViewData(at: view).data == GLTFSimpleMaterial.pngBytes)
    }

    // MARK: - Validation

    @Test(arguments: [
        GLTFTriangleMesh(positions: [], indices: []),
        GLTFTriangleMesh(positions: .triangle, indices: []),
        // A normal per vertex, and this one is a normal short.
        GLTFTriangleMesh(positions: .triangle,
                         normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
                         indices: [0, 1, 2]),
        GLTFTriangleMesh(positions: .triangle,
                         textureCoordinates: [SIMD2(0, 0)],
                         indices: [0, 1, 2]),
        // Four indices are not a whole number of triangles.
        GLTFTriangleMesh(positions: .triangle, indices: [0, 1, 2, 0]),
        // Vertex 3 is one the mesh has not got.
        GLTFTriangleMesh(positions: .triangle, indices: [0, 1, 3]),
        // A position the bounds glTF requires cannot be written from.
        GLTFTriangleMesh(positions: [SIMD3(0, 0, 0), SIMD3(.nan, 0, 0), SIMD3(0, 1, 0)],
                         indices: [0, 1, 2]),
        GLTFTriangleMesh(positions: .triangle,
                         normals: [SIMD3(.infinity, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
                         indices: [0, 1, 2]),
        // A normal has to be a unit vector, which neither of these is.
        GLTFTriangleMesh(positions: .triangle,
                         normals: [SIMD3(0, 0, 100), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
                         indices: [0, 1, 2]),
        GLTFTriangleMesh(positions: .triangle,
                         normals: Array(repeating: SIMD3(0, 0, 0), count: 3),
                         indices: [0, 1, 2]),
        // An image is read at TEXCOORD_0, which this mesh has not got.
        GLTFTriangleMesh(positions: .triangle,
                         indices: [0, 1, 2],
                         material: .picture),
        GLTFTriangleMesh(positions: .triangle,
                         textureCoordinates: [SIMD2(.nan, 0), SIMD2(0, 0), SIMD2(0, 0)],
                         indices: [0, 1, 2]),
        GLTFTriangleMesh(positions: .triangle,
                         indices: [0, 1, 2],
                         material: GLTFSimpleMaterial(baseColorFactor: SIMD4(-1, 1, 1, 1))),
        GLTFTriangleMesh(positions: .triangle,
                         indices: [0, 1, 2],
                         material: GLTFSimpleMaterial(alphaMode: .mask(cutoff: .nan))),
    ])
    func testAMeshGLTFCannotDescribeIsRefusedWithoutChangingTheDocument(mesh: GLTFTriangleMesh) throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.addMesh(mesh, under: 0) }

        #expect(try document.serialize() == before)
    }

    /// glTF holds PNG and JPEG and nothing else, and transcoding is the
    /// caller's to do rather than this package's.
    @Test
    func testAnImageThatIsNeitherPNGNorJPEGIsRefusedWithoutChangingTheDocument() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.serialize()
        var material = GLTFSimpleMaterial.picture
        material.baseColorImage = Data("RIFF____WEBPVP8 ".utf8)

        #expect(throws: VRMError.self) {
            try document.addMesh(.plate(material: material), under: 0)
        }

        #expect(try document.serialize() == before)
    }
}

// MARK: - Fixtures

private extension Array where Element == SIMD3<Float> {
    static var triangle: [SIMD3<Float>] { [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)] }
}

private extension GLTFTriangleMesh {
    /// A unit square on the XY plane, wound counter-clockwise, which is the
    /// billboard this API is for.
    static func plate(material: GLTFSimpleMaterial?) -> GLTFTriangleMesh {
        GLTFTriangleMesh(positions: [SIMD3(-0.5, -0.5, 0), SIMD3(0.5, -0.5, 0),
                                     SIMD3(0.5, 0.5, 0), SIMD3(-0.5, 0.5, 0)],
                         normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
                         textureCoordinates: [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)],
                         indices: [0, 1, 2, 0, 2, 3],
                         material: material)
    }
}

private extension GLTFSimpleMaterial {
    /// The eight byte PNG signature. Nothing here decodes an image, so it
    /// stands for one: what matters is that it is read back unchanged.
    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static var picture: GLTFSimpleMaterial {
        GLTFSimpleMaterial(name: "picture",
                           baseColorFactor: SIMD4(1, 0.5, 0.25, 1),
                           baseColorImage: pngBytes,
                           isUnlit: true,
                           alphaMode: .blend,
                           isDoubleSided: true)
    }
}

// MARK: - Reading back

private extension GLTFDocument {
    /// The one primitive of the mesh hanging on `node`.
    func primitive(onNodeAt node: Int) throws -> GLTF.Mesh.Primitive {
        let nodes = try #require(gltf.nodes)
        let mesh = try #require(nodes[node].mesh)
        let meshes = try #require(gltf.meshes)
        return try #require(meshes[mesh].primitives.first)
    }

    func vector3Attribute(_ key: GLTF.Mesh.Primitive.AttributeKey,
                          of primitive: GLTF.Mesh.Primitive) throws -> [SIMD3<Float>] {
        let index = try #require(primitive.attributes[key])
        return try packed(accessorAt: index).floatElements(.VEC3) { SIMD3($0(0), $0(1), $0(2)) }
    }

    func textureCoordinates(of primitive: GLTF.Mesh.Primitive) throws -> [SIMD2<Float>] {
        let index = try #require(primitive.attributes[.TEXCOORD_0])
        return try packed(accessorAt: index).floatElements(.VEC2) { SIMD2($0(0), $0(1)) }
    }

    func indices(of primitive: GLTF.Mesh.Primitive) throws -> [UInt32] {
        let index = try #require(primitive.indices)
        return try packed(accessorAt: index).unsignedElements(.SCALAR) { $0(0) }
    }

    private func packed(accessorAt index: Int) throws -> PackedAccessor {
        let accessor = try #require(gltf.accessors?[index])
        return try PackedAccessor(accessor: accessor) { index in
            let view = try bufferViewData(at: index)
            return (view.data, view.stride)
        }
    }
}
