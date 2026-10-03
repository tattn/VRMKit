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

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func noLimitLeavesTheAuthoredSizeAlone() throws {
        let authored = try image(width: 512, height: 256)
        let result = GLTFSceneBuilder.clamped(authored, to: nil)
        #expect(result.width == 512)
        #expect(result.height == 256)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func animageWithinTheLimitIsNotRedrawn() throws {
        let authored = try image(width: 256, height: 128)
        let result = GLTFSceneBuilder.clamped(authored, to: 256)
        #expect(result === authored)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func theLongestSideMeetsTheLimitAndTheAspectRatioHolds() throws {
        let authored = try image(width: 1024, height: 512)
        let result = GLTFSceneBuilder.clamped(authored, to: 256)
        #expect(result.width == 256)
        #expect(result.height == 128)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func aVeryTallImageIsLimitedByItsHeight() throws {
        let authored = try image(width: 64, height: 1024)
        let result = GLTFSceneBuilder.clamped(authored, to: 128)
        #expect(result.height == 128)
        #expect(result.width == 8)
    }

    /// A side that would round to zero still has to be a drawable pixel.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func anExtremeAspectRatioKeepsAtLeastOnePixel() throws {
        let authored = try image(width: 4096, height: 1)
        let result = GLTFSceneBuilder.clamped(authored, to: 16)
        #expect(result.width == 16)
        #expect(result.height == 1)
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
