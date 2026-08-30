#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What a first-person camera draws: the meshes it hides whole, and the ones it
/// cuts the head's own triangles out of.
@Suite
@MainActor
struct VRMFirstPersonTests {
    /// A `thirdPersonOnly` mesh goes in first person. What goes is the mesh,
    /// not the node drawing it, so the nodes hanging off that one keep drawing.
    @Test
    func testVRM1ThirdPersonOnlyMeshIsHiddenInFirstPerson() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmLoader = try VRMEntityLoader(withData: TestSupport.seedSanData)
        let vrmEntity = try await vrmLoader.loadEntity()
        let node = try #require(vrmEntity.entity(forNodeAt: 0))
        let mesh = try #require(node.children.first)

        #expect(mesh.isEnabled == true)
        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(mesh.isEnabled == false)
        #expect(node.isEnabled == true)
        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(mesh.isEnabled == true)
    }

    /// glTF lets two nodes draw one mesh, and VRM 1.0 annotates the node rather
    /// than the mesh, so one of the two may go in first person while the other
    /// stays.
    @Test
    func testVRM1AnnotatesEachNodeDrawingAMeshOnItsOwn() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Node 0 draws mesh 0 as `thirdPersonOnly`; the copy draws it as `both`.
        let data = try Self.seedSanSharingMeshZero(copyAnnotatedAs: "both")
        let vrmLoader = try VRMEntityLoader(withData: data)
        let vrmEntity = try await vrmLoader.loadEntity()
        let annotated = try #require(vrmEntity.entity(forNodeAt: 0)?.children.first)
        let copy = try #require(vrmEntity.entity(forNodeAt: Self.seedSanMeshCopyNodeIndex)?.children.first)

        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(annotated.isEnabled == false)
        #expect(copy.isEnabled == true)

        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(annotated.isEnabled == true)
        #expect(copy.isEnabled == true)
    }

    /// The `auto` cut is made as a mesh is built, so a mesh one node draws
    /// `auto` and another draws whole is built twice rather than cut for both.
    @Test
    func testVRM1CutsAMeshOnlyForTheNodesAnnotatedAuto() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Node 0 draws mesh 0 as `auto`, so the head's triangles go; the copy
        // draws it as `both`, so it keeps them.
        let data = try Self.seedSanSharingMeshZero(copyAnnotatedAs: "both") { annotations in
            annotations.map { annotation in
                var annotation = annotation
                if annotation.int("node") == 0 { annotation["type"] = .string("auto") }
                return annotation
            }
        }
        let vrmLoader = try VRMEntityLoader(withData: data, shaders: [])
        let vrmEntity = try await vrmLoader.loadEntity()
        let annotated = try #require(vrmEntity.entity(forNodeAt: 0)?.children.first)
        let copy = try #require(vrmEntity.entity(forNodeAt: Self.seedSanMeshCopyNodeIndex)?.children.first)

        let cutPrimitives = TestSupport.firstPersonCuts(in: annotated)
        #expect(!cutPrimitives.isEmpty)
        #expect(TestSupport.firstPersonCuts(in: copy).isEmpty)
    }

    /// The node index the fixture rewrite below gives its copy of node 0.
    private static let seedSanMeshCopyNodeIndex = 147

    /// Seed-san with a second node drawing node 0's mesh through node 0's skin,
    /// annotated `copyAnnotatedAs`. `modifyAnnotations` rewrites the annotations
    /// the fixture already carries.
    private static func seedSanSharingMeshZero(
        copyAnnotatedAs type: String,
        modifyAnnotations: ([[String: JSONValue]]) -> [[String: JSONValue]] = { $0 }
    ) throws -> Data {
        try TestSupport.modifiedSeedSanData(name: "one mesh drawn by two nodes") { json in
            var nodes = json.objects("nodes")
            guard nodes.count == seedSanMeshCopyNodeIndex,
                  let mesh = nodes.first?.int("mesh"), let skin = nodes.first?.int("skin") else {
                throw VRMError.dataInconsistent("Unexpected Seed-san node layout")
            }
            nodes.append(["name": .string("hair_copy"), "mesh": .int(mesh), "skin": .int(skin)])
            json["nodes"] = .objects(nodes)

            var scenes = json.objects("scenes")
            let roots = (scenes.first?["nodes"]?.arrayValue ?? []) + [.int(seedSanMeshCopyNodeIndex)]
            scenes[0]["nodes"] = .array(roots)
            json["scenes"] = .objects(scenes)

            guard var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRMC_vrm"),
                  var firstPerson = vrm.object("firstPerson") else {
                throw VRMError.dataInconsistent("Missing Seed-san firstPerson")
            }
            let annotations = modifyAnnotations(firstPerson.objects("meshAnnotations"))
            firstPerson["meshAnnotations"] = .objects(
                annotations + [["node": .int(seedSanMeshCopyNodeIndex), "type": .string(type)]]
            )
            vrm["firstPerson"] = .object(firstPerson)
            extensions["VRMC_vrm"] = .object(vrm)
            json["extensions"] = .object(extensions)
        }
    }

    /// An `auto` mesh keeps the triangles no head bone draws, and a primitive
    /// the head draws whole goes with it.
    @Test
    func testFirstPersonAutoDrawsAMeshWithoutTheHeadsTriangles() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Alicia annotates every mesh `Auto`, hers being split head from body.
        let vrmLoader = try VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data, shaders: [])
        let vrmEntity = try await vrmLoader.loadEntity()
        let cut = TestSupport.firstPersonCuts(in: vrmEntity)
        func firstPersonMesh(of catalog: GLTFMergedMeshCatalog) throws -> MeshResource? {
            try catalog.mesh(visibleSlots: catalog.initiallyVisibleSlots, isFirstPerson: true)
        }
        let trimmed = try #require(try cut.first { try firstPersonMesh(of: $0.catalog) != nil })
        let dropped = try #require(try cut.first { try firstPersonMesh(of: $0.catalog) == nil })

        // The trimmed mesh loses triangles without losing all of them.
        let whole = TestSupport.triangleIndexCount(of: trimmed.catalog.fullMesh)
        let headless = TestSupport.triangleIndexCount(of: try #require(try firstPersonMesh(of: trimmed.catalog)))
        #expect(headless > 0)
        #expect(headless < whole)

        vrmEntity.setFirstPersonRenderMode(.firstPerson)
        #expect(TestSupport.drawnTriangleIndexCount(of: trimmed.entity) == headless)
        #expect(dropped.entity.isEnabled == false)

        vrmEntity.setFirstPersonRenderMode(.thirdPerson)
        #expect(TestSupport.drawnTriangleIndexCount(of: trimmed.entity) == whole)
        #expect(dropped.entity.isEnabled == true)
    }
}
#endif
