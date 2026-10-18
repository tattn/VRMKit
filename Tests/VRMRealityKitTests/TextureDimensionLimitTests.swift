#if canImport(RealityKit)
import CoreGraphics
import Foundation
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Capping how large a texture is uploaded at.
@Suite
struct TextureDimensionLimitTests {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil,
                                             width: width,
                                             height: height,
                                             bitsPerComponent: 8,
                                             bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    typealias Clamp = (width: Int, height: Int, limit: Int?, expectedWidth: Int, expectedHeight: Int)

    /// The longest side meets the limit and the aspect ratio holds, while no limit
    /// leaves the authored size alone.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test(arguments: [
        (512, 256, nil, 512, 256),
        (1024, 512, 256, 256, 128),
        (64, 1024, 128, 8, 128),
        // A side that would round to zero still has to be a drawable pixel.
        (4096, 1, 16, 16, 1)
    ] as [Clamp])
    func anImageIsDrawnWithinTheLimitAtItsAspectRatio(_ clamp: Clamp) throws {
        let authored = try image(width: clamp.width, height: clamp.height)
        let result = GLTFSceneBuilder.clamped(authored, to: clamp.limit)
        #expect(result.width == clamp.expectedWidth)
        #expect(result.height == clamp.expectedHeight)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func anImageWithinTheLimitIsNotRedrawn() throws {
        let authored = try image(width: 256, height: 128)
        let result = GLTFSceneBuilder.clamped(authored, to: 256)
        #expect(result === authored)
    }

    /// A PNG with alpha decodes as non-premultiplied, a format Core Graphics draws into
    /// no context of, so it is redrawn as premultiplied rather than left full size.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func anImageWithNonPremultipliedAlphaIsLimitedToo() throws {
        let side = 128
        let provider = try #require(CGDataProvider(data: Data(repeating: 200, count: side * side * 4) as CFData))
        let authored = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                            provider: provider, decode: nil, shouldInterpolate: false,
                                            intent: .defaultIntent))
        let result = GLTFSceneBuilder.clamped(authored, to: 32)
        #expect(result.width == 32 && result.height == 32)
    }

    /// The limit reaches the load rather than stopping at the loader.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @MainActor
    @Test func aModelLoadsWithTheLimitInEffect() async throws {
        let loader = VRMEntityLoader(vrm: try VRM(data: TestSupport.seedSanData),
                                     maxTextureDimension: 64)
        #expect(loader.resources.maxTextureDimension == 64)
        _ = try await loader.loadEntity()
        #expect(!loader.resources.textureCache.isEmpty)
        #expect(loader.resources.textureCache.values.allSatisfy { $0.width <= 64 && $0.height <= 64 })
    }
}
#endif
