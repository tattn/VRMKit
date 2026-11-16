import Foundation
import Testing
import VRMKit

@Suite
struct GLTFAccessorTests {
    /// The bounds are only hints, so a file that writes one as a bare number still loads.
    @Test
    func testBoundsInTheWrongShapeReadAsAbsent() throws {
        let accessor = try decode(#"{"componentType": 5126, "count": 3, "type": "SCALAR", "max": 1, "min": [0]}"#)

        #expect(accessor.max == nil)
        #expect(accessor.min == [0])
        #expect(accessor.count == 3)
    }

    private func decode(_ json: String) throws -> GLTF.Accessor {
        try JSONDecoder().decode(GLTF.Accessor.self, from: Data(json.utf8))
    }
}
