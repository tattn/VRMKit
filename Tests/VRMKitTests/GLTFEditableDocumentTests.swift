import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

@Suite
struct GLTFEditableDocumentTests {
    // MARK: - Round trip

    /// A GLB that is loaded and written back out unchanged has to come back as
    /// the same document, down to the extensions VRMKit does not model.
    @Test(arguments: VRMSampleAsset.allCases)
    func testGLBRoundTripKeepsEveryJSONField(asset: VRMSampleAsset) throws {
        let original = try GLTFDocument(data: asset.data)
        let reloaded = try GLTFDocument(data: try GLTFEditableDocument(data: asset.data).serialize())

        // `buffers` is the one array a round trip rewrites: the resources are
        // consolidated into the single buffer a GLB carries.
        #expect(jsonDifference(try original.rawJSON().removing("buffers"),
                               try reloaded.rawJSON().removing("buffers")) == nil)
        try expectSameBufferViews(original, reloaded)
    }

    /// A `.gltf` with external resources becomes a self-contained GLB: its
    /// buffers and its images move into the one buffer a GLB carries, and
    /// nothing else about the document changes.
    @Test(arguments: GLTFSampleAsset.allCases)
    func testGLTFRoundTripEmbedsItsResourcesAndKeepsEverythingElse(asset: GLTFSampleAsset) throws {
        let original = try GLTFDocument(withURL: asset.url)
        let document = try GLTFEditableDocument(data: asset.data, rootDirectory: asset.rootDirectory)
        let reloaded = try GLTFDocument(data: try document.serialize())

        let left = try original.rawJSON().removing("buffers", "bufferViews", "images")
        let right = try reloaded.rawJSON().removing("buffers", "bufferViews", "images")
        #expect(jsonDifference(left, right) == nil)
        // One view per image read in, appended after the ones the file had.
        let embedded = (original.gltf.images ?? []).filter { $0.uri != nil }.count
        try expectSameBufferViews(original, reloaded, added: embedded)
        try expectSameAccessors(original, reloaded)
        try expectSelfContainedImages(original, reloaded)
    }

    @Test
    func testSerializedGLBKeepsItsChunksAligned() throws {
        // A 5 byte buffer leaves both chunks needing padding.
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQ=", "byteLength": 5}],
            "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 5}]
        }
        """
        let glb = try GLTFEditableDocument(data: Data(json.utf8)).serialize()

        #expect(glb.count % 4 == 0)
        #expect(glb.uint32LE(at: 8) == UInt32(glb.count))
        #expect(glb.uint32LE(at: 12) % 4 == 0)  // the JSON chunk's length
        let binaryChunkLength = glb.uint32LE(at: 20 + Int(glb.uint32LE(at: 12)))
        #expect(binaryChunkLength == 8)  // 5 bytes of buffer, padded
        #expect(try GLTFDocument(data: glb).bufferViewData(at: 0).data == Data([0, 1, 2, 3, 4]))
    }

    /// The typed view is what node indices are resolved through, so it has to
    /// show the edits rather than the state the document was loaded in.
    @Test
    func testTypedSnapshotFollowsEdits() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.typed().nodes?.count ?? 0

        let index = try document.addNode(name: "added")

        #expect(try document.typed().nodes?.count == before + 1)
        #expect(try document.typed().nodes?[index].name == "added")
    }

    // MARK: - Node editing

    @Test
    func testAddNodeAttachesToItsParentAndKeepsExistingIndices() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let nodesBefore = try document.typed().nodes ?? []

        let transform = GLTFNodeTransform(translation: SIMD3(1, 2, 3),
                                          rotation: simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)),
                                          scale: SIMD3(2, 2, 2))
        let index = try document.addNode(name: "hand item", parent: 0, transform: transform)

        let nodes = try #require(try document.typed().nodes)
        #expect(index == nodesBefore.count)
        #expect(nodes[0].children?.contains(index) == true)
        #expect(nodes[index].name == "hand item")
        #expect(nodes[index].translation.x == 1)
        #expect(nodes[index].scale.y == 2)
        // Everything that was there is still where it was.
        #expect(zip(nodesBefore, nodes).allSatisfy { $0.name == $1.name })
    }

    @Test
    func testAddNodeWithoutParentBecomesASceneRoot() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)

        let index = try document.addNode(name: "root item")

        let gltf = try document.typed()
        let scene = try #require(gltf.scenes?[gltf.scene ?? 0])
        #expect(scene.nodes?.contains(index) == true)
    }

    /// A document holding one scene has nothing to name, which is how UniVRM
    /// 0.x writes its models.
    @Test
    func testAddNodeWithoutParentUsesTheOnlySceneOfADocumentNamingNone() throws {
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": []}], "nodes": [{"name": "a"}]}
        """
        let document = try GLTFEditableDocument(data: Data(json.utf8))

        let index = try document.addNode(name: "root item")

        #expect(try document.typed().scenes?[0].nodes?.contains(index) == true)
    }

    /// Several scenes and none named is the document saying nothing about
    /// which to draw, and picking one for it is not this to do.
    @Test
    func testAddNodeWithoutParentNeedsToKnowWhichSceneToAddTo() throws {
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": []}, {"nodes": []}]}
        """
        let document = try GLTFEditableDocument(data: Data(json.utf8))
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.addNode(name: "root item") }
        #expect(try document.serialize() == before)
    }

    /// An edit that throws leaves the document as it was, rather than one
    /// orphaned node larger.
    @Test
    func testAddNodeUnderAMissingParentChangesNothing() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.addNode(name: "item", parent: 100_000) }
        #expect(try document.serialize() == before)
    }

    @Test
    func testSetTransformReplacesAMatrixWithItsTRS() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let index = try document.addNode(name: "item")
        try document.updateNode(at: index) { $0["matrix"] = GLTF.Matrix.identity.values }

        try document.setTransform(GLTFNodeTransform(translation: SIMD3(0, 1, 0)), nodeAt: index)

        let node = try document.node(at: index)
        #expect(node["matrix"] == nil)
        #expect(try document.typed().nodes?[index].translation.y == 1)
        #expect(try document.transform(nodeAt: index).translation == SIMD3(0, 1, 0))
    }

    @Test
    func testNonFiniteTransformsAreRefusedWithoutChangingTheDocument() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let index = try document.addNode(name: "item")
        let before = try document.serialize()

        #expect(throws: VRMError.self) {
            try document.setTransform(GLTFNodeTransform(scale: SIMD3(1, .nan, 1)), nodeAt: index)
        }
        #expect(throws: VRMError.self) {
            try document.addNode(transform: GLTFNodeTransform(
                rotation: simd_quatf(vector: SIMD4(0, 0, 0, .infinity))
            ))
        }
        #expect(try document.serialize() == before)
    }

    @Test
    func testTransformOfAMatrixNodeIsDecomposed() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let index = try document.addNode(name: "item")
        let transform = GLTFNodeTransform(translation: SIMD3(1, 2, 3),
                                          rotation: simd_quatf(angle: .pi / 3, axis: normalize(SIMD3(1, 1, 0))),
                                          scale: SIMD3(2, 2, 2))
        try document.updateNode(at: index) { $0["matrix"] = transform.matrix.columnMajorValues }

        let decomposed = try document.transform(nodeAt: index)

        #expect(simd_distance(decomposed.translation, transform.translation) < 1e-5)
        #expect(simd_distance(decomposed.scale, transform.scale) < 1e-5)
        #expect(abs(abs(simd_dot(decomposed.rotation.vector, transform.rotation.vector)) - 1) < 1e-5)
    }

    /// A flattened axis leaves no rotation to recover, and a mirroring one a
    /// negative scale rather than a rotation. Neither yields NaNs.
    @Test
    func testDegenerateAndMirroringMatricesDecomposeWithoutNaNs() throws {
        let cases: [SIMD3<Float>] = [
            SIMD3(-1, 0, 1), SIMD3(0, -1, 1), SIMD3(1, 1, 0), SIMD3(0, 0, 0), SIMD3(-2, 3, 4),
        ]
        for scale in cases {
            let source = float4x4(SIMD4(scale.x, 0, 0, 0),
                                  SIMD4(0, scale.y, 0, 0),
                                  SIMD4(0, 0, scale.z, 0),
                                  SIMD4(1, 2, 3, 1))
            let decomposed = GLTFNodeTransform(matrix: source)

            #expect(decomposed.rotation.vector.allFinite, "\(scale)")
            #expect(decomposed.scale.allFinite, "\(scale)")
            #expect(decomposed.translation == SIMD3(1, 2, 3), "\(scale)")
            let mirrors = scale.x * scale.y * scale.z < 0
            #expect((decomposed.scale.min() < 0) == mirrors, "\(scale)")
            if scale.min() == 0 || scale.max() == 0 {
                #expect(decomposed.rotation == quat_identity_float, "\(scale)")
            }
        }
    }

    /// glTF wants a unit quaternion, and `rotation` is the caller's to set.
    @Test
    func testANonUnitRotationIsWrittenNormalized() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let index = try document.addNode(name: "item")
        let turn = simd_quatf(angle: .pi / 3, axis: normalize(SIMD3<Float>(0, 1, 0)))

        try document.setTransform(GLTFNodeTransform(rotation: simd_quatf(vector: turn.vector * 4)), nodeAt: index)

        let written = try #require(try document.typed().nodes?[index].rotation)
        let vector = SIMD4<Float>(Float(written.x), Float(written.y), Float(written.z), Float(written.w))
        #expect(abs(simd_length(vector) - 1) < 1e-5)
        #expect(abs(abs(simd_dot(vector, turn.vector)) - 1) < 1e-5)
    }

    /// A quaternion far from unit length still names an orientation. Squaring
    /// its components would lose a tiny one to underflow and a huge one to
    /// overflow, and either would be written out as no rotation at all.
    @Test(arguments: [Float(1e-4), 1e-20, 1e20, 1e30])
    func testARotationFarFromUnitLengthKeepsItsOrientation(magnitude: Float) throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let index = try document.addNode(name: "item")
        let turn = simd_quatf(angle: .pi / 3, axis: normalize(SIMD3<Float>(0, 1, 0)))

        try document.setTransform(GLTFNodeTransform(rotation: simd_quatf(vector: turn.vector * magnitude)),
                                  nodeAt: index)

        let written = try #require(try document.typed().nodes?[index].rotation)
        let vector = SIMD4<Float>(Float(written.x), Float(written.y), Float(written.z), Float(written.w))
        #expect(abs(simd_length(vector) - 1) < 1e-5)
        #expect(abs(abs(simd_dot(vector, turn.vector)) - 1) < 1e-5)
    }

    /// A rotation of no length names none at all, rather than NaNs.
    @Test
    func testAZeroRotationIsWrittenAsNone() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let index = try document.addNode(name: "item")

        try document.setTransform(GLTFNodeTransform(rotation: simd_quatf(vector: .zero)), nodeAt: index)

        #expect(try document.node(at: index)["rotation"] == nil)
    }

    @Test
    func testSetNameRenamesAndClearsANode() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)

        try document.setName("renamed", nodeAt: 0)
        #expect(try document.typed().nodes?[0].name == "renamed")

        try document.setName(nil, nodeAt: 0)
        #expect(try document.typed().nodes?[0].name == nil)
    }

    /// Detaching cuts the links and nothing else, so the subtree survives whole
    /// and unreachable - and can be attached again.
    @Test
    func testDetachNodeUnlinksTheSubtreeWithoutMovingOrErasingAnything() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let parent = try document.addNode(name: "container")
        let child = try document.addNode(name: "child", parent: parent)
        let nodesBefore = try #require(try document.typed().nodes).count

        try document.detachNode(at: parent)

        let gltf = try document.typed()
        let nodes = try #require(gltf.nodes)
        #expect(nodes.count == nodesBefore)
        #expect(nodes[parent].name == "container")
        #expect(nodes[parent].children == [child])
        #expect(nodes[child].name == "child")
        #expect(gltf.scenes?[gltf.scene ?? 0].nodes?.contains(parent) == false)
        #expect(nodes.allSatisfy { $0.children?.contains(parent) != true })

        // Nothing was lost, so it goes back where it was.
        try document.moveNode(at: parent, to: 0)
        #expect(try document.typed().nodes?[0].children?.contains(parent) == true)
    }

    /// A move is a detach and an attach in one, so the subtree leaves every
    /// parent it was under.
    @Test
    func testMoveNodeLeavesItsOldParentAndKeepsItsIndex() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let first = try document.addNode(name: "first")
        let second = try document.addNode(name: "second")
        let moved = try document.addNode(name: "moved", parent: first)

        try document.moveNode(at: moved, to: second)

        let nodes = try #require(try document.typed().nodes)
        #expect(nodes[moved].name == "moved")
        #expect(nodes[second].children == [moved])
        #expect(nodes[first].children == nil)
    }

    @Test
    func testMoveNodeWithoutAParentMakesItASceneRoot() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let parent = try document.addNode(name: "parent")
        let child = try document.addNode(name: "child", parent: parent)

        try document.moveNode(at: child, to: nil)

        let gltf = try document.typed()
        #expect(gltf.nodes?[parent].children == nil)
        #expect(gltf.scenes?[gltf.scene ?? 0].nodes?.contains(child) == true)
    }

    /// A cycle would be walked forever, so the move is refused before any link
    /// is cut.
    @Test
    func testMoveNodeUnderItsOwnDescendantIsRefusedAndChangesNothing() throws {
        let document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let parent = try document.addNode(name: "parent")
        let child = try document.addNode(name: "child", parent: parent)
        let grandchild = try document.addNode(name: "grandchild", parent: child)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.moveNode(at: parent, to: grandchild) }
        #expect(throws: VRMError.self) { try document.moveNode(at: parent, to: parent) }
        #expect(throws: VRMError.self) { try document.moveNode(at: parent, to: 100_000) }
        #expect(try document.serialize() == before)
    }

    // MARK: - Resource layout

    /// A rebase that only clamped would point the view at the first buffer, and
    /// it would come out loadable but reading someone else's bytes.
    @Test
    func testBufferViewNamingAMissingBufferIsRefused() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQ=", "byteLength": 5}],
            "bufferViews": [{"buffer": 7, "byteOffset": 0, "byteLength": 5}]
        }
        """

        #expect(throws: VRMError.self) { try GLTFEditableDocument(data: Data(json.utf8)) }
    }

    /// Merging several buffers into the one a GLB holds moves byte offsets, and
    /// an extension VRMKit cannot read may be naming them itself.
    @Test
    func testSeveralBuffersUnderAnUnknownExtensionAreRefused() throws {
        func json(extensionsUsed: String) -> Data {
            Data("""
            {
                "asset": {"version": "2.0"},
                \(extensionsUsed)
                "buffers": [
                    {"uri": "data:application/octet-stream;base64,AAECAwQ=", "byteLength": 5},
                    {"uri": "data:application/octet-stream;base64,BQYHCAk=", "byteLength": 5}
                ],
                "bufferViews": [
                    {"buffer": 0, "byteOffset": 0, "byteLength": 5},
                    {"buffer": 1, "byteOffset": 0, "byteLength": 5}
                ]
            }
            """.utf8)
        }

        // Nothing unknown declared, so the two buffers are merged as ever.
        let merged = try GLTFEditableDocument(data: json(extensionsUsed: ""))
        #expect(try merged.typed().bufferViews?[1].byteOffset == 8)

        #expect(throws: VRMError.self) {
            try GLTFEditableDocument(data: json(extensionsUsed: #""extensionsUsed": ["ACME_buffer_thing"],"#))
        }
    }

    /// A single-buffer document keeps every offset it had, whatever it
    /// declares.
    @Test
    func testSingleBufferDocumentIsEditedWhateverItDeclares() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["ACME_buffer_thing"],
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQ=", "byteLength": 5}],
            "bufferViews": [{"buffer": 0, "byteOffset": 1, "byteLength": 4}]
        }
        """
        let document = try GLTFEditableDocument(data: Data(json.utf8))

        #expect(try document.typed().bufferViews?[0].byteOffset == 1)
        #expect(try GLTFDocument(data: try document.serialize()).bufferViewData(at: 0).data == Data([1, 2, 3, 4]))
    }

    @Test
    func testEditingNodesOfADocumentWithoutAnyThrows() throws {
        let json = """
        {"asset": {"version": "2.0"}}
        """
        let document = try GLTFEditableDocument(data: Data(json.utf8))

        #expect(throws: VRMError.self) { try document.setName("x", nodeAt: 0) }
        #expect(throws: VRMError.self) { try document.detachNode(at: 0) }
    }

    /// A document holding no scene has nowhere to draw a root, so adding one
    /// gives it the scene to draw it in rather than leaving it unreachable.
    @Test
    func testAddingARootToADocumentWithoutScenesGivesItOne() throws {
        let json = """
        {"asset": {"version": "2.0"}}
        """
        let document = try GLTFEditableDocument(data: Data(json.utf8))

        let index = try document.addNode(name: "first")

        let gltf = try document.typed()
        #expect(gltf.scenes?.count == 1)
        #expect(gltf.scenes?[gltf.scene ?? 0].nodes == [index])
    }

    // MARK: - Helpers

    /// Every image comes back in the GLB's own buffer, holding the bytes of
    /// the file or data URI it was read from.
    private func expectSelfContainedImages(_ lhs: GLTFDocument,
                                           _ rhs: GLTFDocument,
                                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let images = lhs.gltf.images ?? []
        #expect(images.count == rhs.gltf.images?.count ?? 0, sourceLocation: sourceLocation)
        for index in images.indices {
            let embedded = try #require(rhs.gltf.images?[index], sourceLocation: sourceLocation)
            #expect(embedded.uri == nil, "image \(index)", sourceLocation: sourceLocation)
            #expect(embedded.mimeType != nil, "image \(index)", sourceLocation: sourceLocation)
            let view = try #require(embedded.bufferView, "image \(index)", sourceLocation: sourceLocation)
            let expected = try images[index].uri
                .map { try Data(gltfUrlString: $0, relativeTo: lhs.rootDirectory) }
                ?? (try bufferViewBytes(of: lhs, at: #require(images[index].bufferView)))
            #expect(try bufferViewBytes(of: rhs, at: view) == expected,
                    "image \(index)", sourceLocation: sourceLocation)
        }
    }

    /// Compares the bytes every buffer view names, which is the whole of a
    /// glTF's binary side.
    ///
    /// The views are sliced out of the buffers directly rather than read
    /// through ``GLTFDocument``, which bounds a view by the `byteLength` its
    /// buffer declares, and the AliciaSolid fixture declares one shorter than
    /// the views its exporter wrote.
    private func expectSameBufferViews(_ lhs: GLTFDocument,
                                       _ rhs: GLTFDocument,
                                       added: Int = 0,
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let views = lhs.gltf.bufferViews ?? []
        #expect(views.count + added == rhs.gltf.bufferViews?.count ?? 0, sourceLocation: sourceLocation)
        for index in views.indices {
            #expect(try bufferViewBytes(of: lhs, at: index) == (try bufferViewBytes(of: rhs, at: index)),
                    "buffer view \(index)", sourceLocation: sourceLocation)
        }
    }

    private func bufferViewBytes(of document: GLTFDocument, at index: Int) throws -> Data {
        let view = try document.gltf.load(\.bufferViews, at: index)
        let buffer = try document.bufferData(at: view.buffer)
        let start = buffer.startIndex + view.byteOffset
        return buffer[start ..< start + view.byteLength]
    }
}

extension float4x4 {
    /// The 16 values glTF writes a matrix as.
    var columnMajorValues: [Float] {
        (0..<4).flatMap { column in (0..<4).map { self[column][$0] } }
    }
}

extension SIMD where Scalar: FloatingPoint {
    /// Whether every lane is a real number, which a decomposition that divided
    /// by a zero axis would not be.
    var allFinite: Bool { indices.allSatisfy { self[$0].isFinite } }
}
