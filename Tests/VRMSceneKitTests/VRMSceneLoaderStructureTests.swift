import VRMKit
import VRMTestSupport
@testable import VRMSceneKit
import SceneKit
import simd
import Testing

/// The malformed node graphs a scene load has to reject before it builds a
/// node, and the primitive modes it flat shades a mesh without normals in.
@Suite
struct VRMSceneLoaderStructureTests {
    private func loader(_ modify: (inout [String: JSONValue]) throws -> Void) throws -> VRMSceneLoader {
        try VRMSceneLoader(withData: VRMSampleAsset.seedSan.rewritingJSON(modify))
    }

    /// glTF node hierarchies are forests. A cyclic one would recurse forever, so
    /// it has to fail the load instead.
    @Test
    func testCyclicNodeHierarchyFailsTheLoad() throws {
        let loader = try loader { json in
            json["nodes"] = [["children": [1]], ["children": [0]]]
            json["scenes"] = [["nodes": [0]]]
        }

        #expect(throws: VRMError.self) { try loader.loadScene() }
    }

    /// A node reached from two parents is neither renderable as a tree nor valid
    /// glTF: adding it to the second parent would silently move it there.
    @Test
    func testNodeWithTwoParentsFailsTheLoad() throws {
        let loader = try loader { json in
            json["nodes"] = [["children": [2]], ["children": [2]], [:]]
            json["scenes"] = [["nodes": [0, 1]]]
        }

        #expect(throws: VRMError.self) { try loader.loadScene() }
    }

    /// `scene.nodes` names root nodes. Attaching one that already has a parent
    /// would reparent it, so the resulting hierarchy would depend on the order
    /// `scene.nodes` happens to list them in.
    @Test
    func testSceneRootThatIsAlreadyAChildFailsTheLoad() throws {
        let loader = try loader { json in
            json["nodes"] = [["children": [1]], [:]]
            json["scenes"] = [["nodes": [0, 1]]]
        }

        #expect(throws: VRMError.self) { try loader.loadScene() }
    }

    /// A skin the loader would index out of bounds, or bind one joint twice, is
    /// rejected rather than trusted.
    @Test
    func testSkinWithABadJointListFailsTheLoad() throws {
        for joints in [[0, 0], [0, 9999]] {
            let loader = try loader { json in
                json["skins"] = [["joints": .numbers(joints)]]
            }
            #expect(throws: VRMError.self) { try loader.loadScene() }
        }
    }

    /// glTF omits `NORMAL` to ask for flat normals, and a strip states the same
    /// faces a triangle list would, so both modes get one face normal per
    /// triangle rather than an average shared between neighbours.
    @Test(arguments: [GLTF.Mesh.Primitive.Mode.TRIANGLES.rawValue,
                      GLTF.Mesh.Primitive.Mode.TRIANGLE_STRIP.rawValue])
    func testNormalsAreFlatForEveryFaceMode(mode: Int) throws {
        let loader = try loader { json in
            var meshes = json.objects("meshes")
            var primitives = meshes[0].objects("primitives")
            var attributes = try #require(primitives[0].object("attributes"))
            attributes.removeValue(forKey: "NORMAL")
            primitives[0]["attributes"] = .object(attributes)
            primitives[0]["mode"] = .int(mode)
            primitives[0].removeValue(forKey: "targets")
            meshes[0]["primitives"] = .objects([primitives[0]])
            meshes[0].removeValue(forKey: "extras")
            json["meshes"] = .objects(meshes)
        }

        let primitive = try #require(loader.mesh(withMeshIndex: 0, skinIndex: nil, nodeIndex: 0).childNodes.first)
        let geometry = try #require(primitive.geometry)
        let normals = try #require(geometry.sources.first { $0.semantic == .normal }).createVertices()
        let vertices = try #require(geometry.sources.first { $0.semantic == .vertex }).createVertices()

        // Flat shading gives every triangle its own three vertices.
        #expect(normals.count == vertices.count)
        #expect(vertices.count.isMultiple(of: 3))
        for corner in stride(from: 0, to: vertices.count, by: 3) {
            let face = simd_cross(vertices[corner + 1] - vertices[corner],
                                  vertices[corner + 2] - vertices[corner])
            guard simd_length_squared(face) > 0 else { continue }
            let expected = simd_normalize(face)
            for offset in 0..<3 {
                #expect(simd_distance(normals[corner + offset], expected) < 1e-4)
            }
        }
    }

    /// Flat shading dereferences every triangle index. A malformed one is
    /// rejected before that happens instead of indexing past the vertex array.
    @Test
    func testTriangleIndexBeyondPositionsFailsTheLoad() throws {
        let loader = try loader { json in
            var meshes = json.objects("meshes")
            var primitives = meshes[0].objects("primitives")
            var attributes = try #require(primitives[0].object("attributes"))
            let position = try #require(attributes.int("POSITION"))
            attributes.removeValue(forKey: "NORMAL")
            primitives[0]["attributes"] = .object(attributes)
            primitives[0].removeValue(forKey: "targets")
            meshes[0]["primitives"] = .objects([primitives[0]])
            json["meshes"] = .objects(meshes)

            var accessors = json.objects("accessors")
            accessors[position]["count"] = 1
            json["accessors"] = .objects(accessors)
        }

        #expect(throws: VRMError.self) { try loader.mesh(withMeshIndex: 0, skinIndex: nil, nodeIndex: 0) }
    }

    /// Two scenes may name the same nodes. An `SCNNode` has one parent and an
    /// expression poses the materials, so each load has to build its own.
    @Test
    func testScenesSharingNodesLoadIndependentSceneGraphs() throws {
        let loader = try loader { json in
            var scenes = json.objects("scenes")
            let first = try #require(scenes.first)
            scenes.append(first)
            json["scenes"] = .objects(scenes)
        }

        let first = try loader.loadScene(withSceneIndex: 0)
        let second = try loader.loadScene(withSceneIndex: 1)

        #expect(first !== second)
        // Neither scene may have had its nodes stolen by the other.
        #expect(!first.vrmNode.childNodes.isEmpty)
        #expect(first.vrmNode.childNodes.count == second.vrmNode.childNodes.count)
        let firstNodes = Set(first.vrmNode.allDescendants.map(ObjectIdentifier.init))
        let secondNodes = Set(second.vrmNode.allDescendants.map(ObjectIdentifier.init))
        #expect(firstNodes.count == secondNodes.count)
        #expect(firstNodes.isDisjoint(with: secondNodes))

        // Each scene drives its own materials, so an expression moves one alone.
        let materials = { (scene: VRMScene) in
            Set(scene.vrmNode.allDescendants.flatMap { $0.geometry?.materials ?? [] }.map(ObjectIdentifier.init))
        }
        #expect(!materials(first).isEmpty)
        #expect(materials(first).isDisjoint(with: materials(second)))
    }
}

private extension SCNNode {
    var allDescendants: [SCNNode] {
        childNodes.flatMap { [$0] + $0.allDescendants }
    }
}
