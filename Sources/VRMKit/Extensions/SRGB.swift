import Foundation

/// The sRGB transfer function, which separates the color spaces VRM 0.x and
/// MToon 1.0 keep their colors in: VRM 0.x writes the Unity material colors as
/// sRGB, while every MToon 1.0 factor is linear.
package enum SRGB {
    package static func toLinear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    package static func fromLinear(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
