import Foundation
import simd

/// How a standard Unlit / PBR glTF material converts into MToon, whether it is
/// a renderer toon-shading a model that carries no MToon data of its own or a
/// document being saved with MToon materials.
public struct MToonConversionStyle: Equatable, Sendable {
    /// The canonical conversion style. Its MToon values come directly from the
    /// specification defaults shared with authored MToon materials.
    ///
    /// The initializer defaults to these rather than to the specification
    /// constants, which are `package` and cannot appear in a public default.
    public static let defaultStyle = MToonConversionStyle(
        shadeColorScale: 0.8,
        shadingToonyFactor: MToonMaterialDescriptor.SpecDefault.shadingToonyFactor,
        shadingShiftFactor: MToonMaterialDescriptor.SpecDefault.shadingShiftFactor,
        outlineWidthMode: .worldCoordinates,
        outlineWidthFactor: MToonMaterialDescriptor.SpecDefault.outlineWidthFactor,
        outlineColorFactor: MToonMaterialDescriptor.SpecDefault.outlineColorFactor
    )

    /// The shade color is the base color scaled by this factor per channel, so
    /// the shadowed side keeps the material's hue. 0...1.
    public let shadeColorScale: Float
    /// 0...1; higher values sharpen the boundary between the lit and shaded sides.
    public let shadingToonyFactor: Float
    /// Shifts where the lit-shade boundary sits; 0 keeps the MToon default. -1...1.
    public let shadingShiftFactor: Float
    /// How ``outlineWidthFactor`` is measured; irrelevant while it is 0.
    public let outlineWidthMode: MToonOutlineWidthMode
    /// Width of the inverted-hull outline, measured per ``outlineWidthMode``:
    /// meters for `.worldCoordinates`, a fraction of the screen height for
    /// `.screenCoordinates`. 0 draws no outline, and no width is negative.
    public let outlineWidthFactor: Float
    /// 0...1 per channel.
    public let outlineColorFactor: SIMD4<Float>

    /// The outline as MToon writes it: a width of 0 is no outline, which MToon
    /// spells ``MToonOutlineWidthMode/none``.
    package var outline: (mode: MToonOutlineWidthMode, width: Float) {
        outlineWidthFactor > 0 ? (outlineWidthMode, outlineWidthFactor) : (.none, 0)
    }

    /// Every value is held to the range MToon gives it here rather than on the
    /// way out to a file, so that a preview and a save agree.
    public init(shadeColorScale: Float = MToonConversionStyle.defaultStyle.shadeColorScale,
                shadingToonyFactor: Float = MToonConversionStyle.defaultStyle.shadingToonyFactor,
                shadingShiftFactor: Float = MToonConversionStyle.defaultStyle.shadingShiftFactor,
                outlineWidthMode: MToonOutlineWidthMode = MToonConversionStyle.defaultStyle.outlineWidthMode,
                outlineWidthFactor: Float = MToonConversionStyle.defaultStyle.outlineWidthFactor,
                outlineColorFactor: SIMD4<Float> = MToonConversionStyle.defaultStyle.outlineColorFactor) {
        self.shadeColorScale = shadeColorScale.clamped(to: 0...1)
        self.shadingToonyFactor = shadingToonyFactor.clamped(to: 0...1)
        self.shadingShiftFactor = shadingShiftFactor.clamped(to: -1...1)
        self.outlineWidthMode = outlineWidthMode
        self.outlineWidthFactor = max(outlineWidthFactor, 0)
        self.outlineColorFactor = outlineColorFactor.clamped(lowerBound: .zero, upperBound: .one)
    }
}
