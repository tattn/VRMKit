#if canImport(RealityKit)
import CoreGraphics
import simd

/// The color space a renderer's output is read in, which decides the numbers RealityKit
/// renders glTF colors with.
///
/// RealityKit renders in linear Display P3: it converts color textures and tints into it
/// from the color space they are tagged with, and `RealityView` and `ARView` present the
/// result as Display P3. A `RealityRenderer` writes those same values into the app's
/// texture, so an app reading that texture as sRGB sees every color pulled toward gray.
public enum GLTFOutputColorSpace: Sendable, Hashable {
    /// RealityKit's own, for `RealityView` and `ARView`.
    case displayP3
    /// For a `RealityRenderer` whose output texture is read as sRGB. Colors reach
    /// RealityKit tagged as Display P3, which it keeps as they are, so it renders with the
    /// sRGB numbers the glTF holds, as a renderer working in sRGB does.
    case sRGB

    /// What glTF's sRGB colors are tagged with on their way to RealityKit.
    var taggedColorSpace: CGColorSpace {
        switch self {
        case .displayP3: CGColorSpace(name: CGColorSpace.sRGB)!
        case .sRGB: CGColorSpace(name: CGColorSpace.displayP3)!
        }
    }

    /// A glTF color image tagged as sRGB numbers in this output.
    ///
    /// The specification has loaders read glTF images as sRGB whatever color profile they
    /// embed, so the pixels are retagged rather than converted. An image with no RGB
    /// primaries, such as grayscale, is left as decoded.
    func colorImage(_ image: CGImage) -> CGImage {
        guard let space = image.colorSpace else { return image }
        switch space.model {
        case .rgb:
            return image.copy(colorSpace: taggedColorSpace) ?? image
        case .indexed:
            guard space.baseColorSpace?.model == .rgb,
                  let indexed = Self.indexedColorSpace(like: space, base: taggedColorSpace) else { return image }
            return image.copy(colorSpace: indexed) ?? image
        default:
            return image
        }
    }

    private static func indexedColorSpace(like space: CGColorSpace, base: CGColorSpace) -> CGColorSpace? {
        guard let table = space.colorTable, !table.isEmpty else { return nil }
        return CGColorSpace(indexedBaseSpace: base, last: table.count / 3 - 1, colorTable: table)
    }

    /// A glTF color as RealityKit takes it for a tint, tagged as ``colorImage(_:)`` tags images.
    func color(_ color: SIMD4<Float>) -> VRMColor {
        switch self {
        case .displayP3:
            VRMColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: CGFloat(color.w))
        case .sRGB:
            VRMColor(displayP3Red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
                     alpha: CGFloat(color.w))
        }
    }

    /// The glTF color a tint made by ``color(_:)`` holds. RealityKit hands a tint back in
    /// the linear form of its color space, so it is read in the space it was tagged with.
    func components(of color: VRMColor) -> SIMD4<Float> {
        guard let components = color.cgColor.converted(to: taggedColorSpace, intent: .defaultIntent, options: nil)?
            .components, components.count == 4 else { return SIMD4<Float>(1, 1, 1, 1) }
        return SIMD4<Float>(components.map { Float($0) })
    }
}
#endif
