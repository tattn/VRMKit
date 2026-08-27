import CoreGraphics
import Foundation
import ImageIO

/// Splits glTF's packed metallic-roughness image into the linear grayscale
/// images the rendering backends consume: roughness from green, metalness from
/// blue.
///
/// The factors are the multipliers glTF applies to the sampled channels, baked
/// in here for a backend with nowhere else to put them.
package func metallicRoughnessImages(from image: CGImage,
                                     metallicFactor: Float = 1,
                                     roughnessFactor: Float = 1) throws -> (metal: CGImage, rough: CGImage) {
    let pixelCount = image.width * image.height
    var rgba = Data(count: pixelCount * 4)
    try rgba.withUnsafeMutableBytes { pixels in
        let context = try CGContext(data: pixels.baseAddress,
                                    width: image.width,
                                    height: image.height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    // These channels are data, not premultiplied color.
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ??? ._dataInconsistent("failed to create a metallic-roughness bitmap context")
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    var metal = Data(count: pixelCount)
    var rough = Data(count: pixelCount)
    rgba.withUnsafeBytes { source in
        metal.withUnsafeMutableBytes { metal in
            rough.withUnsafeMutableBytes { rough in
                guard let source = source.bindMemory(to: UInt8.self).baseAddress,
                      let metal = metal.bindMemory(to: UInt8.self).baseAddress,
                      let rough = rough.bindMemory(to: UInt8.self).baseAddress else { return }
                for pixel in 0..<pixelCount {
                    metal[pixel] = scaled(source[pixel * 4 + 2], by: metallicFactor)
                    rough[pixel] = scaled(source[pixel * 4 + 1], by: roughnessFactor)
                }
            }
        }
    }
    return (try grayscaleImage(width: image.width, height: image.height, pixels: metal),
            try grayscaleImage(width: image.width, height: image.height, pixels: rough))
}

private func scaled(_ channel: UInt8, by factor: Float) -> UInt8 {
    guard factor != 1 else { return channel }
    return UInt8((Float(channel) * factor).rounded().clamped(to: 0...255))
}

private func grayscaleImage(width: Int, height: Int, pixels: Data) throws -> CGImage {
    let provider = try CGDataProvider(data: pixels as CFData)
        ??? ._dataInconsistent("failed to create grayscale image data")
    return try CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
        ??? ._dataInconsistent("failed to create a grayscale image")
}

extension Data {
    /// The image the bytes hold, or nil when no decoder on this platform reads
    /// them. Its size is in pixels, unlike the points a ``VRMImage`` reports.
    var decodedImage: CGImage? {
        guard let source = CGImageSourceCreateWithData(self as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
