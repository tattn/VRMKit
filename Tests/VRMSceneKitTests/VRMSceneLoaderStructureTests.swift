import VRMKit
import VRMTestSupport
@testable import VRMSceneKit
import SceneKit
import Testing

/// The malformed node graphs a scene load has to reject before it builds a
/// node, and the primitive modes it estimates normals for.
@Suite
struct VRMSceneLoaderStructureTests {
    private func loader(_ modify: (inout [String: Any]) throws -> Void) throws -> VRMSceneLoader {
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
                json["skins"] = [["joints": joints]]
            }
            #expect(throws: VRMError.self) { try loader.loadScene() }
        }
    }

    /// glTF omits `NORMAL` to ask for flat normals, and a strip states the same
    /// faces a triangle list would, so both modes get them estimated.
    @Test(arguments: [GLTF.Mesh.Primitive.Mode.TRIANGLES.rawValue,
                      GLTF.Mesh.Primitive.Mode.TRIANGLE_STRIP.rawValue])
    func testNormalsAreEstimatedForEveryFaceMode(mode: Int) throws {
        let loader = try loader { json in
            var meshes = try #require(json["meshes"] as? [[String: Any]])
            var primitives = try #require(meshes[0]["primitives"] as? [[String: Any]])
            var attributes = try #require(primitives[0]["attributes"] as? [String: Any])
            attributes.removeValue(forKey: "NORMAL")
            primitives[0]["attributes"] = attributes
            primitives[0]["mode"] = mode
            primitives[0]["targets"] = nil
            meshes[0]["primitives"] = [primitives[0]]
            meshes[0]["extras"] = nil
            json["meshes"] = meshes
        }

        let primitive = try #require(loader.mesh(withMeshIndex: 0).childNodes.first)
        let geometry = try #require(primitive.geometry)
        let normals = try #require(geometry.sources.first { $0.semantic == .normal })
        let vertices = try #require(geometry.sources.first { $0.semantic == .vertex })
        #expect(normals.vectorCount == vertices.vectorCount)
    }

    /// Estimating normals dereferences every triangle index. A malformed one is
    /// rejected before that happens instead of indexing past the vertex array.
    @Test
    func testTriangleIndexBeyondPositionsFailsTheLoad() throws {
        let loader = try loader { json in
            var meshes = try #require(json["meshes"] as? [[String: Any]])
            var primitives = try #require(meshes[0]["primitives"] as? [[String: Any]])
            var attributes = try #require(primitives[0]["attributes"] as? [String: Any])
            let position = try #require(attributes["POSITION"] as? Int)
            attributes.removeValue(forKey: "NORMAL")
            primitives[0]["attributes"] = attributes
            primitives[0]["targets"] = nil
            meshes[0]["primitives"] = [primitives[0]]
            json["meshes"] = meshes

            var accessors = try #require(json["accessors"] as? [[String: Any]])
            accessors[position]["count"] = 1
            json["accessors"] = accessors
        }

        #expect(throws: VRMError.self) { try loader.mesh(withMeshIndex: 0) }
    }
}
