import CoreGraphics
import simd

extension VRMColor {
    package convenience init(simd color: SIMD4<Float>) {
        self.init(red: CGFloat(color.x),
                  green: CGFloat(color.y),
                  blue: CGFloat(color.z),
                  alpha: CGFloat(color.w))
    }

    package var simd: SIMD4<Float> {
        #if os(macOS)
        let color = usingColorSpace(.deviceRGB) ?? self
        return SIMD4<Float>(Float(color.redComponent),
                            Float(color.greenComponent),
                            Float(color.blueComponent),
                            Float(color.alphaComponent))
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
        #endif
    }
}
