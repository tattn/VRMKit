import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

@Suite
struct GLTFPruneTests {
    // MARK: - Detached subtrees

    /// The file shrinks by what the detached subtree drew, and what the model still
    /// draws comes back byte for byte through indices that have moved.
    @Test(arguments: VRMSampleAsset.allCases)
    func testPruneReclaimsWhatADetachedSubtreeDrew(asset: VRMSampleAsset) throws {
        var document = try GLTFEditableDocument(data: asset.data)
        try document.detachNode(at: GLTFNodeIndex(try #require(drawingSceneRoot(of: try document.typed()))))
        let before = try GLTFDocument(data: try document.serialize())
        let expected = try drawnContents(of: before)

        let reclaimed = try document.prune()

        let after = try document.serialize()
        #expect(reclaimed.reclaimedByteCount > 0)
        #expect(after.count < asset.data.count)
        let saved = try GLTFDocument(data: after)
        #expect(try drawnContents(of: saved) == expected)
        // The arrays really did shrink, so the indices really did move.
        #expect((saved.gltf.accessors).count < (before.gltf.accessors).count)
        try expectAWellFormedDocument(saved)
        expectReadableAccessors(saved)
    }

    /// Every index the VRM extensions hold moves with the arrays, so the avatar names
    /// the same bones. A binding to what a node drew goes with the drawing.
    @Test(arguments: VRMSampleAsset.allCases)
    func testPruneKeepsTheVRMExtensionsPointingAtTheSameEntries(asset: VRMSampleAsset) throws {
        var document = try GLTFEditableDocument(data: asset.data)
        let detached = try #require(drawingSceneRoot(of: try document.typed()))
        let gone = [try #require(try document.typed().nodes[detached].name),
                    try #require(try document.typed().nodes[detached].mesh
                        .flatMap { try document.typed().meshes[$0].name })]
        try document.detachNode(at: GLTFNodeIndex(detached))
        let before = try GLTFDocument(data: try document.serialize())
        let bones = try humanoidBoneNames(of: before)
        let joints = try springBoneJointNames(of: before)
        let subjects = try renderedSubjectNames(of: before)
        #expect(!bones.isEmpty)
        #expect(!subjects.isDisjoint(with: gone))

        try document.prune()

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(try humanoidBoneNames(of: saved) == bones)
        #expect(try springBoneJointNames(of: saved) == joints)
        #expect(try renderedSubjectNames(of: saved) == subjects.subtracting(gone))
    }

    /// A VRM's thumbnail is not drawn by any scene, so a document detached down to
    /// nothing still has to come back with it.
    @Test(arguments: VRMSampleAsset.allCases)
    func testPruneKeepsTheThumbnailOfAModelWithNothingLeftToDraw(asset: VRMSampleAsset) throws {
        let original = try GLTFDocument(data: asset.data)
        let expected = try #require(try thumbnailBytes(of: original))
        var document = try GLTFEditableDocument(data: asset.data)

        for root in try document.typed().scenes[try document.defaultSceneIndex()].nodes ?? [] {
            try document.detachNode(at: GLTFNodeIndex(root))
        }
        try document.prune()

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(try thumbnailBytes(of: saved) == expected)
        #expect(saved.gltf.meshes.isEmpty)
        try expectAWellFormedDocument(saved)
        expectReadableAccessors(saved)
    }

    /// Detaching an appended container leaves the whole copy unreachable, so pruning
    /// has to put the document back where it started.
    @Test
    func testPruneUndoesAnAppendThatWasDetachedAgain() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        // Settled first, so the comparison sees the append alone rather than the gaps
        // the model was exported with.
        try document.prune()
        let before = try document.serialize()

        let container = try document.append(try GLTFDocument(withURL: GLTFSampleAsset.animatedTriangle.url),
                                            under: 0,
                                            name: "prop")
        try document.detachNode(at: container)
        let reclaimed = try document.prune()

        #expect(reclaimed.reclaimedByteCount > 0)
        #expect(try document.serialize() == before)
    }

    /// A channel driving a node nothing draws goes with the keyframes only it read,
    /// while the rest of the animation stays.
    @Test
    func testPruneDropsOnlyTheChannelsThatDriveWhatWasDetached() throws {
        var document = try GLTFEditableDocument(data: Data(Self.mixedAnimationDocument.utf8))

        try document.detachNode(at: 2)
        // The detached channel's own keyframes, and nothing the other reads.
        #expect(try document.prune().reclaimedByteCount == 8)

        let saved = try GLTFDocument(data: try document.serialize())
        let animation = try #require(saved.gltf.animations.first)
        #expect(saved.gltf.animations.count == 1)
        #expect(animation.channels.map(\.target.node) == [0])
        #expect(animation.channels.map(\.sampler) == [0])
        #expect(animation.samplers.count == 1)
        #expect(saved.gltf.nodes.count == 2)
        try expectAWellFormedDocument(saved)
    }

    /// An animation's channels index its own samplers, and pruning compacts those, so
    /// a channel naming one it does not hold is refused, not dropped.
    @Test(arguments: ["999", "-1"])
    func testPruneRejectsOutOfRangeAnimationSampler(sampler: String) throws {
        let json = Self.mixedAnimationDocument.replacingOccurrences(of: #""sampler": 1"#,
                                                                   with: #""sampler": \#(sampler)"#)
        var document = try GLTFEditableDocument(data: Data(json.utf8))

        #expect(throws: VRMError.self) { try document.prune() }
    }

    /// A `VRMC_vrm_animation` document describes a humanoid rather than a model, so
    /// what it drives is what it keeps.
    @Test(arguments: VRMASampleAsset.allCases)
    func testPruneKeepsEveryChannelOfAVRMAnimation(asset: VRMASampleAsset) throws {
        var document = try GLTFEditableDocument(document: try GLTFDocument(withURL: asset.url))
        let before = try GLTFDocument(data: try document.serialize())

        try document.prune()

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(saved.gltf.animations.count == before.gltf.animations.count)
        #expect(saved.gltf.animations.map { $0.channels.count }
                == before.gltf.animations.map { $0.channels.count })
        #expect(saved.gltf.nodes.count == before.gltf.nodes.count)
        try expectAWellFormedDocument(saved)
        expectReadableAccessors(saved)
    }

    /// A document naming no scene draws nothing, and pruning to what it draws would
    /// take all of it.
    @Test
    func testPruneRefusesADocumentThatNamesNoScene() throws {
        let json = """
        {"asset": {"version": "2.0"}, "nodes": [{"name": "orphan"}]}
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.prune() }

        #expect(try document.serialize() == before)
    }

    /// A reference naming an entry the document does not hold would come out of the
    /// compaction deleted, so pruning refuses such a document.
    @Test
    func testPruneRefusesADocumentNamingAnEntryItDoesNotHold() throws {
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "scene": 0, \
        "nodes": [{"name": "root", "children": [7]}]}
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.prune() }

        #expect(try document.serialize() == before)
    }

    /// A list of references spells "nothing" by leaving the element out, so a negative
    /// one is no index at all and is refused rather than quietly dropped.
    @Test
    func testPruneRefusesANegativeIndexInAListOfReferences() throws {
        let json = """
        {"asset": {"version": "2.0"}, "scenes": [{"nodes": [0]}], "scene": 0, \
        "nodes": [{"name": "root", "children": [-1]}]}
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.prune() }

        #expect(try document.serialize() == before)
    }

    /// A node something names keeps its transform and nothing else: not the subtree
    /// under it, nor what that subtree drew.
    @Test
    func testPruneKeepsANamedNodeWithoutWhatHungUnderIt() throws {
        var document = try GLTFEditableDocument(data: Data(Self.namedButUndrawnDocument.utf8))

        #expect(try document.prune().reclaimedByteCount == 8)

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(saved.gltf.nodes.map(\.name) == ["named", "root", "drawn"])
        #expect(saved.gltf.nodes[0].children == nil)
        #expect(saved.gltf.nodes[1].children == [2])
        #expect(saved.gltf.meshes.map(\.name) == ["kept"])
        #expect(saved.gltf.nodes[2].mesh == 0)
        #expect(saved.gltf.cameras.isEmpty)
        let extensions = try #require(try saved.rawJSON().object("extensions"))
        // The spring bone still swings the node it named, and the expression has lost
        // the bind to a node that has stopped drawing.
        #expect(extensions.object(GLTFExtension.springBone.rawValue)?
            .objects("springs").first?.objects("joints").first?.index("node") == 0)
        #expect(extensions.object(GLTFExtension.vrm1.rawValue)?.object("expressions")?
            .object("preset")?.object("happy")?["morphTargetBinds"] == nil)
        try expectAWellFormedDocument(saved)
        expectReadableAccessors(saved)
    }

    /// glTF has no node weighting or skinning a mesh it does not draw, so what a node
    /// stops drawing takes those with it.
    @Test
    func testPruneLeavesANamedNodeNothingItCannotHaveWithoutAMesh() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_springBone"],
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQFBgc=", "byteLength": 8}],
            "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 8}],
            "accessors": [{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"}],
            "skins": [{"joints": [1]}],
            "meshes": [{"name": "shared", "primitives": [{"attributes": {"POSITION": 0}}]}],
            "nodes": [
                {"name": "named", "mesh": 0, "skin": 0, "weights": [0.5], "camera": 0},
                {"name": "root", "children": [2]},
                {"name": "drawn", "mesh": 0}
            ],
            "cameras": [{"type": "perspective", "perspective": {"yfov": 1, "znear": 0.1}}],
            "scenes": [{"nodes": [1]}],
            "scene": 0,
            "extensions": {"VRMC_springBone": {"springs": [{"joints": [{"node": 0}]}]}}
        }
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))

        try document.prune()

        // The mesh survives on the node that draws it, and the named node keeps none
        // of what it read that mesh through.
        let node = try #require(try document.typed().nodes.first)
        #expect(node.name == "named")
        #expect(node.mesh == nil)
        #expect(node.skin == nil)
        #expect(node.camera == nil)
        let raw = try #require(try GLTFDocument(data: try document.serialize()).rawJSON().objects(.nodes).first)
        #expect(raw["weights"] == nil)
        #expect(try document.typed().skins.isEmpty)
        #expect(try document.typed().cameras.isEmpty)
        #expect(try document.typed().meshes.count == 1)
    }

    /// A `VRMC_vrm_animation` need not draw anything, so naming no scene is not what
    /// makes one unreadable.
    @Test
    func testPruneKeepsASceneLessVRMAnimation() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "extensionsUsed": ["VRMC_vrm_animation"],
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQFBgc=", "byteLength": 8}],
            "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 8}],
            "accessors": [{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"}],
            "animations": [{
                "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}],
                "samplers": [{"input": 0, "output": 0}]
            }],
            "nodes": [{"name": "armature", "children": [1]}, {"name": "hips"}],
            "extensions": {
                "VRMC_vrm_animation": {
                    "specVersion": "1.0",
                    "humanoid": {"humanBones": {"hips": {"node": 1}}}
                }
            }
        }
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))

        #expect(try document.prune().reclaimedByteCount == 0)

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(saved.gltf.animations.first?.channels.count == 1)
        #expect(saved.gltf.nodes.contains { $0.name == "hips" } == true)
        expectReadableAccessors(saved)
    }

    /// An extension the document does not declare is caught wherever it sits, including
    /// inside another extension's payload.
    @Test
    func testPruneRefusesAnUndeclaredExtensionInsideAnother() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "nodes": [{"name": "root"}],
            "scenes": [{"nodes": [0]}],
            "scene": 0,
            "extensions": {"VRMC_vrm": {"extensions": {"ACME_x": {"node": 0}}}}
        }
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.prune() }

        #expect(try document.serialize() == before)
    }

    // MARK: - What the walk has to keep

    /// Sparse overrides, embedded images and a meshopt view's compressed slice are all
    /// still read, so only the two orphaned views go.
    @Test
    func testPruneKeepsSparseEmbeddedAndCompressedData() throws {
        var document = try GLTFEditableDocument(data: Data(Self.sixtyFourByteDocument.utf8))
        let original = try GLTFDocument(data: try document.serialize())

        // Four bytes of orphaned view, and eight more of another.
        #expect(try document.prune().reclaimedByteCount == 12)

        let saved = try GLTFDocument(data: try document.serialize())
        let views = saved.gltf.bufferViews
        #expect(views.map(\.byteLength) == [12, 4, 12, 8, 8])
        #expect(views.map(\.byteOffset) == [0, 12, 16, 28, 36])
        // The image and the meshopt view moved down into the orphan's place.
        for (index, was) in [0: 0, 1: 1, 2: 2, 3: 4, 4: 5] {
            #expect(try saved.bufferViewData(at: index).data == (try original.bufferViewData(at: was).data),
                    "buffer view \(was)")
        }
        #expect(try compressedSlice(of: saved, at: 4) == (try compressedSlice(of: original, at: 5)))
        try expectAWellFormedDocument(saved)
    }

    /// A buffer no view carves up is a buffer nothing reads.
    @Test
    func testPruneReclaimsABufferNoViewCarvesUp() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQFBgc=", "byteLength": 8}]
        }
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))

        #expect(try document.prune().reclaimedByteCount == 8)

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(saved.gltf.buffers.isEmpty)
        #expect(saved.gltf.bufferViews.isEmpty)
    }

    /// An extension this package cannot read may reach a mesh or a view in a shape the
    /// walk does not know, so the document is refused whether declared or not.
    @Test(arguments: [#"{"extensionsUsed": ["ACME_buffer_thing"]}"#,
                      #"{"extensions": {"ACME_buffer_thing": {"bufferView": 0}}}"#,
                      #"{"extensionsUsed": ["KHR_animation_pointer"]}"#])
    func testPruneRefusesAnExtensionItCannotFollow(declaration: String) throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            \(declaration.dropFirst().dropLast()),
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQFBgc=", "byteLength": 8}],
            "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 8}]
        }
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.prune() }

        #expect(try document.serialize() == before)
    }

    /// A skin reaches its joints without reaching the scene they hang in, so what a
    /// joint draws has to survive either walk order.
    @Test
    func testPruneKeepsWhatASkinReachedBeforeTheHierarchyDid() throws {
        let json = """
        {
            "asset": {"version": "2.0"},
            "buffers": [{"uri": "data:application/octet-stream;base64,AAECAwQFBgc=", "byteLength": 8}],
            "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 8}],
            "accessors": [{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"}],
            "meshes": [{"name": "skinned", "primitives": [{"attributes": {"POSITION": 0}}]},
                       {"name": "onTheJoint", "primitives": [{"attributes": {"POSITION": 0}}]}],
            "skins": [{"joints": [3]}],
            "nodes": [
                {"name": "root", "children": [1, 2]},
                {"name": "boneRoot", "children": [3]},
                {"name": "renderer", "mesh": 0, "skin": 0},
                {"name": "bone", "mesh": 1}
            ],
            "scenes": [{"nodes": [0]}],
            "scene": 0
        }
        """
        var document = try GLTFEditableDocument(data: Data(json.utf8))

        #expect(try document.prune().reclaimedByteCount == 0)

        let saved = try GLTFDocument(data: try document.serialize())
        #expect(saved.gltf.meshes.map(\.name) == ["skinned", "onTheJoint"])
        #expect(saved.gltf.nodes.count == 4)
        try expectAWellFormedDocument(saved)
    }

    // MARK: - Doing nothing

    @Test
    func testPruneOfADocumentWithNothingOrphanedChangesNothing() throws {
        var document = GLTFEditableDocument()
        try document.addMesh(GLTFTriangleMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                              indices: [0, 1, 2]))
        let before = try document.serialize()

        #expect(try document.prune().reclaimedByteCount == 0)

        #expect(try document.serialize() == before)
    }

    @Test
    func testPruneOfADocumentWithoutBufferViewsChangesNothing() throws {
        var document = GLTFEditableDocument()
        try document.addNode(name: "empty")
        let before = try document.serialize()

        #expect(try document.prune().reclaimedByteCount == 0)

        #expect(try document.serialize() == before)
    }

    /// The second call finds nothing, which says the first left the document laid out
    /// the way it reads it.
    @Test(arguments: VRMSampleAsset.allCases)
    func testPruneIsIdempotent(asset: VRMSampleAsset) throws {
        var document = try GLTFEditableDocument(data: asset.data)
        try document.detachNode(at: GLTFNodeIndex(try #require(drawingSceneRoot(of: try document.typed()))))

        #expect(try document.prune().reclaimedByteCount > 0)
        let pruned = try document.serialize()

        #expect(try document.prune().reclaimedByteCount == 0)
        #expect(try document.serialize() == pruned)
    }

    // MARK: - Helpers

    /// Every index the document holds, checked against the array it points into, plus the
    /// minimums glTF gives its arrays and views. The references come from ``GLTFReferences``,
    /// so the rule and the check cannot drift apart.
    private func expectAWellFormedDocument(_ document: GLTFDocument,
                                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let json = try document.rawJSON()
        let resolve: GLTFIndexMap = { array, index, _ in
            #expect(index < json.count(array),
                    "index \(index) into \(array.rawValue)", sourceLocation: sourceLocation)
            return index
        }
        for array in GLTFArray.allCases {
            #expect(json[array] == nil || json.count(array) > 0,
                    "\(array.rawValue) is empty", sourceLocation: sourceLocation)
            for entry in json.objects(array) {
                _ = GLTFReferences.rewriting(entry, of: array, with: resolve)
            }
        }
        _ = GLTFReferences.rewritingRootExtensions(json.object("extensions") ?? [:], with: resolve)

        let bytes = json.objects(.buffers).first.flatMap { $0.int("byteLength") } ?? 0
        for (index, view) in (document.gltf.bufferViews).enumerated() {
            #expect(view.byteLength >= 1, "buffer view \(index)", sourceLocation: sourceLocation)
            #expect(view.byteOffset + view.byteLength <= bytes,
                    "buffer view \(index)", sourceLocation: sourceLocation)
        }

    }

    /// Reading each accessor is what says its view is still big enough. Only for documents
    /// whose bytes mean what they say, so no meshopt views.
    private func expectReadableAccessors(_ document: GLTFDocument,
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        for index in (document.gltf.accessors).indices {
            #expect(throws: Never.self, "accessor \(index)", sourceLocation: sourceLocation) {
                try packedData(of: document, at: index)
            }
        }
    }

    /// Every mesh the document's scenes reach, read through its accessors, so two documents
    /// match only if they draw the same thing.
    private func drawnContents(of document: GLTFDocument) throws -> Set<String> {
        let gltf = document.gltf
        var contents: Set<String> = []
        var pending = gltf.scenes.flatMap { $0.nodes ?? [] }
        var visited: Set<Int> = []
        while let index = pending.popLast() {
            guard visited.insert(index).inserted, let node = gltf.nodes[safe: index] else { continue }
            pending.append(contentsOf: node.children ?? [])
            guard let mesh = node.mesh.flatMap({ gltf.meshes[safe: $0] }) else { continue }
            for (number, primitive) in mesh.primitives.enumerated() {
                var accessors = primitive.attributes
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { (name: $0.key.rawValue, accessor: $0.value) }
                if let indices = primitive.indices {
                    accessors.append((name: "indices", accessor: indices))
                }
                let read = try accessors.map { attribute in
                    "\(attribute.name):\(try packedData(of: document, at: attribute.accessor).hashValue)"
                }
                let material = primitive.material.flatMap { gltf.materials[safe: $0]?.name } ?? "-"
                contents.insert("\(node.name ?? "-")/\(mesh.name ?? "-")#\(number) \(material) \(read)")
            }
        }
        return contents
    }

    private func packedData(of document: GLTFDocument, at index: Int) throws -> Data {
        try document.gltf.load(\.accessors, at: index).packedData(bufferView: document.bufferViewProvider)
    }

    /// The node each humanoid bone names, by name rather than by index.
    private func humanoidBoneNames(of document: GLTFDocument) throws -> [String: String] {
        let extensions = try document.rawJSON().object("extensions") ?? [:]
        let names = { (node: Int?) in node.flatMap { document.gltf.nodes[safe: $0]?.name } ?? "-" }
        if let bones = extensions.object(GLTFExtension.vrm0.rawValue)?.object("humanoid")?.objects("humanBones") {
            return Dictionary(bones.compactMap { bone in
                bone.string("bone").map { ($0, names(bone.index("node"))) }
            }, uniquingKeysWith: { first, _ in first })
        }
        let bones = extensions.object(GLTFExtension.vrm1.rawValue)?.object("humanoid")?.object("humanBones") ?? [:]
        return bones.compactMapValues { names($0.objectValue?.index("node")) }
    }

    /// What the VRM extensions bind to, named by the mesh VRM 0.x binds through and the
    /// node VRM 1.0 binds through.
    private func renderedSubjectNames(of document: GLTFDocument) throws -> Set<String> {
        let extensions = try document.rawJSON().object("extensions") ?? [:]
        let mesh = { (index: Int?) in index.flatMap { document.gltf.meshes[safe: $0]?.name } ?? "-" }
        let node = { (index: Int?) in index.flatMap { document.gltf.nodes[safe: $0]?.name } ?? "-" }
        let vrm0 = extensions.object(GLTFExtension.vrm0.rawValue) ?? [:]
        let vrm1 = extensions.object(GLTFExtension.vrm1.rawValue) ?? [:]
        var names = Set((vrm0.object("firstPerson") ?? [:]).objects("meshAnnotations")
            .map { mesh($0.index("mesh")) })
        names.formUnion((vrm0.object("blendShapeMaster") ?? [:]).objects("blendShapeGroups")
            .flatMap { $0.objects("binds").map { mesh($0.index("mesh")) } })
        names.formUnion((vrm1.object("firstPerson") ?? [:]).objects("meshAnnotations")
            .map { node($0.index("node")) })
        for group in ["preset", "custom"] {
            for (_, expression) in vrm1.object("expressions")?.object(group) ?? [:] {
                names.formUnion((expression.objectValue ?? [:]).objects("morphTargetBinds")
                    .map { node($0.index("node")) })
            }
        }
        return names
    }

    /// The nodes the spring bones swing, by name, in order.
    private func springBoneJointNames(of document: GLTFDocument) throws -> [String] {
        let extensions = try document.rawJSON().object("extensions") ?? [:]
        let names = { (node: Int?) in node.flatMap { document.gltf.nodes[safe: $0]?.name } ?? "-" }
        let springs = (extensions.object(GLTFExtension.springBone.rawValue) ?? [:]).objects("springs")
        let groups = (extensions.object(GLTFExtension.vrm0.rawValue)?.object("secondaryAnimation") ?? [:])
            .objects("boneGroups")
        return springs.flatMap { $0.objects("joints").map { names($0.index("node")) } }
            + groups.flatMap { ($0.ints("bones") ?? []).map { names($0) } }
    }

    /// A scene root drawing a mesh, so detaching it leaves something to reclaim.
    private func drawingSceneRoot(of gltf: GLTF) -> Int? {
        let scene = gltf.scene ?? 0
        return (gltf.scenes[scene].nodes ?? []).last { gltf.nodes[safe: $0]?.mesh != nil }
    }

    private func thumbnailBytes(of document: GLTFDocument) throws -> Data? {
        let extensions = try document.rawJSON().object("extensions") ?? [:]
        let image = extensions.object(GLTFExtension.vrm1.rawValue)?.object("meta")?.index("thumbnailImage")
            // VRM 0.x names the thumbnail's texture rather than its image.
            ?? extensions.object(GLTFExtension.vrm0.rawValue)?.object("meta")?.index("texture")
                .flatMap { document.gltf.textures[safe: $0]?.source }
        guard let view = image.flatMap({ document.gltf.images[safe: $0]?.bufferView }) else { return nil }
        return try document.bufferViewData(at: view).data
    }

    /// The bytes `EXT_meshopt_compression` adds to a buffer view.
    private func compressedSlice(of document: GLTFDocument, at view: Int) throws -> Data {
        let meshopt = try #require(try document.rawJSON().objects(.bufferViews)[view]
            .object("extensions")?.object(GLTFExtension.meshoptCompression.rawValue))
        let buffer = try document.bufferData(at: 0)
        let start = buffer.startIndex + (meshopt.int("byteOffset") ?? 0)
        return buffer[start ..< start + (try #require(meshopt.int("byteLength")))]
    }

    /// A subtree no scene reaches whose root a spring bone names, so the root outlives the
    /// child it drew through. 0-7 are the child's vertices, 8-15 the surviving node's.
    private static let namedButUndrawnDocument = """
    {
        "asset": {"version": "2.0"},
        "extensionsUsed": ["VRMC_vrm", "VRMC_springBone"],
        "buffers": [{
            "uri": "data:application/octet-stream;base64,AAECAwQFBgcICQoLDA0ODw==",
            "byteLength": 16
        }],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 8},
                        {"buffer": 0, "byteOffset": 8, "byteLength": 8}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"},
                      {"bufferView": 1, "componentType": 5126, "count": 2, "type": "SCALAR"}],
        "cameras": [{"type": "perspective", "perspective": {"yfov": 1, "znear": 0.1}}],
        "meshes": [{"name": "onTheChild", "primitives": [{"attributes": {"POSITION": 0}}]},
                   {"name": "kept", "primitives": [{"attributes": {"POSITION": 1}}]}],
        "nodes": [
            {"name": "named", "children": [1]},
            {"name": "child", "mesh": 0, "camera": 0},
            {"name": "root", "children": [3]},
            {"name": "drawn", "mesh": 1}
        ],
        "scenes": [{"nodes": [2]}],
        "scene": 0,
        "extensions": {
            "VRMC_springBone": {"springs": [{"joints": [{"node": 0}]}]},
            "VRMC_vrm": {
                "expressions": {"preset": {"happy": {"morphTargetBinds": [{"node": 1, "index": 0, "weight": 1}]}}}
            }
        }
    }
    """

    /// One animation over two nodes, one of which the test detaches: 0-7 are the surviving
    /// channel's keyframes, 8-15 the other's.
    private static let mixedAnimationDocument = """
    {
        "asset": {"version": "2.0"},
        "buffers": [{
            "uri": "data:application/octet-stream;base64,AAECAwQFBgcICQoLDA0ODw==",
            "byteLength": 16
        }],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 8},
                        {"buffer": 0, "byteOffset": 8, "byteLength": 8}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"},
                      {"bufferView": 1, "componentType": 5126, "count": 2, "type": "SCALAR"}],
        "animations": [{
            "channels": [{"sampler": 0, "target": {"node": 0, "path": "scale"}},
                         {"sampler": 1, "target": {"node": 2, "path": "scale"}}],
            "samplers": [{"input": 0, "output": 0}, {"input": 1, "output": 1}]
        }],
        "nodes": [{"name": "kept"}, {"name": "root", "children": [0, 2]}, {"name": "detached"}],
        "scenes": [{"nodes": [1]}],
        "scene": 0
    }
    """

    /// A document over 64 bytes numbered 0 to 63, holding one of everything the walk has to
    /// follow and two views nothing reaches: 0-11 positions, 12-15 and 16-27 the sparse
    /// override, 28-31 orphaned, 32-39 the image, 40-47 the meshopt fallback, 48-55 its
    /// compressed bytes, 56-63 orphaned.
    private static let sixtyFourByteDocument = """
    {
        "asset": {"version": "2.0"},
        "extensionsUsed": ["EXT_meshopt_compression"],
        "extensionsRequired": ["EXT_meshopt_compression"],
        "buffers": [{
            "uri": "data:application/octet-stream;base64,\
    AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+Pw==",
            "byteLength": 64
        }],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 12},
            {"buffer": 0, "byteOffset": 12, "byteLength": 4},
            {"buffer": 0, "byteOffset": 16, "byteLength": 12},
            {"buffer": 0, "byteOffset": 28, "byteLength": 4},
            {"buffer": 0, "byteOffset": 32, "byteLength": 8},
            {
                "buffer": 0, "byteOffset": 40, "byteLength": 8, "byteStride": 4,
                "extensions": {"EXT_meshopt_compression": {
                    "buffer": 0, "byteOffset": 48, "byteLength": 8,
                    "byteStride": 4, "count": 2, "mode": "ATTRIBUTES"
                }}
            },
            {"buffer": 0, "byteOffset": 56, "byteLength": 8}
        ],
        "accessors": [
            {
                "bufferView": 0, "componentType": 5126, "count": 1, "type": "VEC3",
                "sparse": {
                    "count": 1,
                    "indices": {"bufferView": 1, "byteOffset": 0, "componentType": 5123},
                    "values": {"bufferView": 2, "byteOffset": 0}
                }
            },
            {"bufferView": 5, "componentType": 5126, "count": 2, "type": "VEC2"}
        ],
        "images": [{"bufferView": 4, "mimeType": "image/png"}],
        "textures": [{"source": 0}],
        "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "material": 0}]}],
        "nodes": [{"mesh": 0}],
        "scenes": [{"nodes": [0]}],
        "scene": 0
    }
    """
}
