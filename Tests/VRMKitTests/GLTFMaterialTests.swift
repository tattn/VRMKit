import Foundation
import Testing
import VRMKit

@Suite
struct GLTFMaterialTests {
    /// Files in the wild write the factors short or long (a VRoid Studio export gives
    /// emissiveFactor 4 components) and UniVRM loads them, so a stated component is read
    /// and a missing one is the spec's default.
    @Test
    func testFactorsAreReadLeniently() throws {
        let material = try decode(
            #"{"emissiveFactor": [1, 0.5, 0, 1], "pbrMetallicRoughness": {"baseColorFactor": [0.25, 0.5]}}"#
        )

        #expect(material.emissiveFactor == SIMD3<Float>(1, 0.5, 0))
        #expect(material.pbrMetallicRoughness?.baseColorFactor == SIMD4<Float>(0.25, 0.5, 1, 1))
    }

    /// A factor the file does not state reads as the spec's default.
    @Test
    func testAbsentFactorsReadAsTheSpecDefaults() throws {
        let material = try decode(#"{"pbrMetallicRoughness": {}}"#)

        #expect(material.emissiveFactor == .zero)
        #expect(material.pbrMetallicRoughness?.baseColorFactor == SIMD4<Float>(repeating: 1))
    }

    private func decode(_ json: String) throws -> GLTF.Material {
        try JSONDecoder().decode(GLTF.Material.self, from: Data(json.utf8))
    }
}
