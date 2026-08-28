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
}
