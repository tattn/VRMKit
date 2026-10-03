#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What recoloring a plain glTF's material at runtime does on screen.
@Suite
@MainActor
struct MaterialColorRenderingTests {
    private static let size = 64

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func cube(emission: SIMD4<Float>?) async throws -> Entity {
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.animatedMorphCube.url,
                                                shaders: [MToonShader(source: .convertAll(MToonConversionStyle()))]).loadEntity()
        if let emission {
            for index in entity.gltf.materials.indices {
                entity.setMaterialColor(emission, for: .emissionColor, ofMaterial: index)
            }
        }
        entity.waitForMaterialStateWrites()
        let root = Entity()
        root.addChild(entity)
        root.scale = SIMD3<Float>(repeating: 0.4)
        return root
    }

    /// Mean color of the drawn pixels in the middle of the frame.
    private func centerColor(_ image: [[SIMD3<Float>]]) -> SIMD3<Float> {
        let middle = image.count / 2
        var sum = SIMD3<Float>(repeating: 0)
        var count: Float = 0
        for row in image[(middle - 4)..<(middle + 4)] {
            for pixel in row[(middle - 4)..<(middle + 4)] where pixel.max() > 8 {
                sum += pixel
                count += 1
            }
        }
        return count > 0 ? sum / count : .zero
    }

    @Test
    func testEmissionColorAddsToTheSurface() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable else { return }
        let bare = centerColor(try OffscreenRenderer.render(await cube(emission: nil), size: Self.size))
#if os(visionOS)
        guard bare.max() > 0 else { return }
#endif
        #expect(bare.max() > 0, "the cube must be drawn")
        let glowing = centerColor(try OffscreenRenderer.render(await cube(emission: SIMD4<Float>(1, 0, 0, 1)),
                                                               size: Self.size))

        #expect(glowing.x > bare.x + 20, "red: \(bare.x) -> \(glowing.x)")
        #expect(abs(glowing.y - bare.y) < 4, "green: \(bare.y) -> \(glowing.y)")
        #expect(abs(glowing.z - bare.z) < 4, "blue: \(bare.z) -> \(glowing.z)")
    }
}
#endif
