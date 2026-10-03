#if canImport(RealityKit)
import CoreGraphics
import Foundation
import Metal
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// The numbers glTF colors reach RealityKit with, for each output color space.
@Suite
@MainActor
struct OutputColorSpaceTests {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    private func image(rgb: [UInt8], space: CGColorSpace) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(rgb + [255]) as CFData))
        return try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                    space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent))
    }

    private static func linear(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func anSRGBOutputTagsColorImagesAsDisplayP3() throws {
        let tagged = GLTFOutputColorSpace.sRGB.colorImage(try image(rgb: [200, 100, 0], space: Self.sRGB))
        #expect(tagged.colorSpace?.name == CGColorSpace.displayP3)
    }

    /// glTF has loaders ignore an embedded profile: the pixels are sRGB numbers regardless.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func aDisplayP3OutputReadsAnyProfileAsSRGB() throws {
        let tagged = GLTFOutputColorSpace.displayP3.colorImage(try image(rgb: [200, 100, 0], space: Self.displayP3))
        #expect(tagged.colorSpace?.name == CGColorSpace.sRGB)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func aGrayscaleImageIsLeftAsDecoded() throws {
        let provider = try #require(CGDataProvider(data: Data([128]) as CFData))
        let gray = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                                        space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent))
        #expect(GLTFOutputColorSpace.sRGB.colorImage(gray) === gray)
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func anIndexedImageKeepsItsPaletteUnderTheNewTag() throws {
        let palette: [UInt8] = [200, 100, 0, 10, 20, 30]
        let indexed = try #require(CGColorSpace(indexedBaseSpace: Self.sRGB, last: 1, colorTable: palette))
        let provider = try #require(CGDataProvider(data: Data([1]) as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                                         space: indexed,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let space = try #require(GLTFOutputColorSpace.sRGB.colorImage(image).colorSpace)
        #expect(space.baseColorSpace?.name == CGColorSpace.displayP3)
        #expect(space.colorTable == palette)
    }

    /// The sRGB color of every texel of the texture ``loadedTexel(outputColorSpace:)`` loads.
    private static let probe = SIMD3<UInt8>(200, 100, 0)

    /// The texel a loaded color texture holds, linear, for a texture of ``probe`` alone.
    /// One color throughout keeps which texel is read, and any filtering or compression
    /// of the stored texture, out of the comparison.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func loadedTexel(outputColorSpace: GLTFOutputColorSpace) async throws -> SIMD3<Float> {
        let png = try OffscreenRenderer.makeTexturePNG(size: 16) { _, _ in Self.probe }
        let data = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            json["images"] = .objects([["uri": .string("data:image/png;base64,\(png.base64EncodedString())")]])
        }
        let loader = try GLTFEntityLoader(withData: data, rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory,
                                          outputColorSpace: outputColorSpace)
        _ = try await loader.loadEntity()
        let resource = try #require(loader.resources.textureCache.first { $0.key.semantic == .color }?.value)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: resource.width,
                                                                  height: resource.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        try await resource.copy(to: texture)
        var texel = [Float](repeating: 0, count: 4)
        texture.getBytes(&texel, bytesPerRow: resource.width * 16,
                         from: MTLRegionMake2D(resource.width / 2, resource.height / 2, 1, 1),
                         mipmapLevel: 0)
        return SIMD3<Float>(texel[0], texel[1], texel[2])
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func anSRGBOutputRendersTheSRGBNumbersOfATexture() async throws {
        let expected = SIMD3<Float>(Self.linear(Float(Self.probe.x) / 255), Self.linear(Float(Self.probe.y) / 255),
                                    Self.linear(Float(Self.probe.z) / 255))
        let texel = try await loadedTexel(outputColorSpace: .sRGB)
#if os(visionOS)
        // The visionOS simulator in CI reads a texture tagged Display P3 back as all zero,
        // however long it waits, so an empty read there says nothing about its colors.
        let isReadable = texel != .zero
#else
        let isReadable = true
#endif
        if isReadable {
            #expect(abs(texel - expected).max() < 0.005, "\(texel) vs \(expected)")
        }
        // RealityKit's own conversion pulls the orange toward gray.
        let converted = try await loadedTexel(outputColorSpace: .displayP3)
        #expect(converted.x < expected.x - 0.02 && converted.z > expected.z + 0.01, "\(converted)")
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test(arguments: [GLTFOutputColorSpace.displayP3, .sRGB])
    func aBaseColorFactorReadsBackAsAuthored(outputColorSpace: GLTFOutputColorSpace) throws {
        let factor = SIMD4<Float>(0.9, 0.6, 0.4, 1)
        let data = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            var materials = json.objects("materials")
            var pbr = materials[0].object("pbrMetallicRoughness") ?? [:]
            pbr["baseColorFactor"] = .simd(factor)
            materials[0]["pbrMetallicRoughness"] = .object(pbr)
            json["materials"] = .objects(materials)
        }
        let loader = try GLTFEntityLoader(withData: data, rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory,
                                          outputColorSpace: outputColorSpace)
        let material = try #require(try loader.inspector.material(withMaterialIndex: 0) as? PhysicallyBasedMaterial)
        #expect(abs(material.currentColor(for: .color, in: outputColorSpace) - factor).max() < 0.0001)
    }
}
#endif
