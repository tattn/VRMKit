import CoreGraphics
import Testing
@testable import VRMKit

/// glTF packs roughness in the green channel of one image and metalness in its
/// blue one, and multiplies each by the factor beside it.
@Suite
struct MetallicRoughnessImageTests {
    /// One pixel, roughness 128 and metalness 64.
    private func packedImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil,
                                             width: 1,
                                             height: 1,
                                             bitsPerComponent: 8,
                                             bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: 4)
        (pixels[0], pixels[1], pixels[2], pixels[3]) = (0, 128, 64, 255)
        return try #require(context.makeImage())
    }

    private func grey(of image: CGImage) throws -> UInt8 {
        let context = try #require(CGContext(data: nil,
                                             width: 1,
                                             height: 1,
                                             bitsPerComponent: 8,
                                             bytesPerRow: 1,
                                             space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.data).bindMemory(to: UInt8.self, capacity: 1).pointee
    }

    @Test
    func testTheChannelsAreSplitUntouchedWithoutFactors() throws {
        let images = try metallicRoughnessImages(from: try packedImage())

        #expect(try grey(of: images.metal) == 64)
        #expect(try grey(of: images.rough) == 128)
    }

    /// A factor over the range the channel holds is held to it.
    @Test
    func testEachFactorScalesItsOwnChannel() throws {
        let images = try metallicRoughnessImages(from: try packedImage(),
                                                 metallicFactor: 0.5,
                                                 roughnessFactor: 4)

        #expect(try grey(of: images.metal) == 32)
        #expect(try grey(of: images.rough) == 255)
    }
}
