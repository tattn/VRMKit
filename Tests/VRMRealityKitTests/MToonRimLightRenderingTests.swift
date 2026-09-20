#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What the runtime rim light does on screen: it lights the side the light is on
/// and leaves the other side as it was, which the parameter rows cannot show.
@Suite
@MainActor
struct MToonRimLightRenderingTests {
    private static let size = 128

    /// A cube turned 45° so both visible faces meet the camera at a grazing enough
    /// angle for a Fresnel term to show; head-on, every normal faces the camera and
    /// the rim is zero everywhere.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func cube(rimLight: MToonRimLight?) async throws -> Entity {
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.animatedMorphCube.url,
                                                      shaders: [MToonShader(source: .convertAll(MToonConversionStyle()))]).loadEntity()
        entity.setMToonRimLight(rimLight)
        entity.waitForMToonParameterWrites()
        let root = Entity()
        root.addChild(entity)
        root.scale = SIMD3<Float>(repeating: 0.4)
        root.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        return root
    }

    /// Mean brightness of the drawn pixels in the left and right halves of the middle rows.
    private func halfBrightness(_ image: [[SIMD3<Float>]]) -> (left: Float, right: Float) {
        let rows = image[(image.count / 2 - 8)..<(image.count / 2 + 8)]
        func mean(_ columns: Range<Int>) -> Float {
            var sum: Float = 0
            var count = 0
            for row in rows {
                for pixel in row[columns] where pixel.max() > 8 {
                    sum += (pixel.x + pixel.y + pixel.z) / 3
                    count += 1
                }
            }
            return count > 0 ? sum / Float(count) : 0
        }
        let width = image[0].count
        return (mean(0..<(width / 2)), mean((width / 2)..<width))
    }

    /// A 45° face meets the camera at 1 - cos 45° ≈ 0.29 of the Fresnel edge, so the
    /// band has to be wide (0.9) to reach it; the color is far above 1 so the change
    /// is unmistakable after tone mapping.
    private func rim(wrap: Float) -> MToonRimLight {
        MToonRimLight(color: SIMD3<Float>(repeating: 8), direction: SIMD3<Float>(1, 0, 0),
                      width: 0.9, softness: 0, wrap: wrap, viewBend: 0)
    }

    @Test
    func testRimLightBrightensTheEdgeFacingTheLightOnly() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable else { return }
        let bare = halfBrightness(try OffscreenRenderer.render(await cube(rimLight: nil), size: Self.size))
        let lit = halfBrightness(try OffscreenRenderer.render(await cube(rimLight: rim(wrap: 0)), size: Self.size))

        #expect(lit.right > bare.right + 20, "right face: \(bare.right) -> \(lit.right)")
        #expect(abs(lit.left - bare.left) < 4, "left face: \(bare.left) -> \(lit.left)")
    }

    /// The wrap carries the band around the side that faces away from the light.
    @Test
    func testWrapCarriesTheRimAroundTheShadowedSide() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable else { return }
        let bare = halfBrightness(try OffscreenRenderer.render(await cube(rimLight: nil), size: Self.size))
        let wrapped = halfBrightness(try OffscreenRenderer.render(await cube(rimLight: rim(wrap: 1)), size: Self.size))

        #expect(wrapped.right > bare.right + 20, "right face: \(bare.right) -> \(wrapped.right)")
        #expect(wrapped.left > bare.left + 20, "left face: \(bare.left) -> \(wrapped.left)")
    }
}
#endif
