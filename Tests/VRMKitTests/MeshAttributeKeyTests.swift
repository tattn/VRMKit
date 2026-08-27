import Foundation
import Testing
@testable import VRMKit

/// How a primitive's vertex attributes survive a decode and a rewrite.
@Suite
struct MeshAttributeKeyTests {
    private typealias AttributeKey = GLTF.Mesh.Primitive.AttributeKey

    private static func decodePrimitive(_ json: String) throws -> GLTF.Mesh.Primitive {
        try JSONDecoder().decode(GLTF.Mesh.Primitive.self, from: Data(json.utf8))
    }

    /// glTF names attributes rather than numbering them, and an asset may carry
    /// names this loader has no constant for, which dropping at decode time would
    /// silently cost a mesh the influences it was authored with.
    @Test
    func testAnAttributeThisLoaderHasNoConstantForSurvivesTheDecode() throws {
        let primitive = try Self.decodePrimitive("""
            {"attributes": {"POSITION": 0, "TEXCOORD_2": 1, "JOINTS_1": 2, "WEIGHTS_1": 3, "_BATCHID": 4}}
            """)

        #expect(primitive.attributes[.POSITION] == 0)
        #expect(primitive.attributes[.texcoord(2)] == 1)
        #expect(primitive.attributes[.joints(1)] == 2)
        #expect(primitive.attributes[.weights(1)] == 3)
        #expect(primitive.attributes[AttributeKey(rawValue: "_BATCHID")] == 4)
    }

    /// A dictionary of attributes has to encode as the JSON object glTF reads,
    /// not as the array of alternating keys and values a plain `Hashable` key
    /// would leave behind.
    @Test
    func testAttributesAndMorphTargetsEncodeAsJSONObjects() throws {
        let primitive = try Self.decodePrimitive("""
            {"attributes": {"POSITION": 0, "NORMAL": 1}, "targets": [{"POSITION": 2}]}
            """)

        let encoded = try JSONEncoder().encode(primitive)
        let json = try #require(try JSONValue(parsing: encoded).objectValue)

        #expect(json.object("attributes") == ["POSITION": 0, "NORMAL": 1])
        let targets = try #require(json["targets"]?.arrayValue)
        #expect(targets == [["POSITION": 2]])
    }

    /// A dictionary has no order, and SceneKit resolves a material's UV mapping
    /// channel by which of the geometry's texcoord sources comes first, so a
    /// model's UV sets would swap from one run to the next.
    @Test
    func testAttributesSortIntoTheOrderGLTFNamesThemIn() {
        let attributes: [AttributeKey: Int] = [
            .WEIGHTS_0: 0, .TEXCOORD_1: 1, .POSITION: 2, .texcoord(4): 3,
            .JOINTS_0: 4, .NORMAL: 5, .TEXCOORD_0: 6, .COLOR_0: 7, .TANGENT: 8,
        ]

        #expect(attributes.sortedByKey.map(\.key) == [
            .POSITION, .NORMAL, .TANGENT, .TEXCOORD_0, .TEXCOORD_1,
            .COLOR_0, .JOINTS_0, .WEIGHTS_0,
            // One this loader has no constant for sorts after the ones it does.
            .texcoord(4),
        ])
    }
}
