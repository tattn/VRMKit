#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// How the built-in Unlit path meets RealityKit's tone mapping, rendered by a
/// `RealityRenderer` that has it turned off.
@Suite
@MainActor
struct UnlitToneMappingTests {
    private static let factor = SIMD4<Float>(0.8, 0.4, 0.2, 1)

    private static func linear(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test(arguments: [true, false])
    func anUnlitColorRendersAsAuthoredOnlyWhenNotCompensating(compensatesToneMapping: Bool) async throws {
        let data = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            var materials = json.objects("materials")
            materials[0]["pbrMetallicRoughness"] = .object(["baseColorFactor": .simd(Self.factor)])
            materials[0]["extensions"] = .object(["KHR_materials_unlit": .object([:])])
            json["materials"] = .objects(materials)
        }
        let loader = try GLTFEntityLoader(withData: data, rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory,
                                          shaders: [], outputColorSpace: .sRGB,
                                          compensatesToneMapping: compensatesToneMapping)
        let entity = try await loader.loadEntity()
        // The quad covers the upper-right quarter of the frame.
        let pixel = try OffscreenRenderer.render(entity, size: 16)[4][12]
        let expected = SIMD3(Self.linear(Self.factor.x), Self.linear(Self.factor.y), Self.linear(Self.factor.z)) * 255
        if compensatesToneMapping {
            // The pre-inverted tone curve has nothing to undo it, so the color comes out brighter.
            #expect(pixel.x > expected.x + 20 && pixel.y > expected.y + 5, "\(pixel) vs \(expected)")
        } else {
            #expect(abs(pixel - expected).max() <= 2, "\(pixel) vs \(expected)")
        }
    }
}
#endif
