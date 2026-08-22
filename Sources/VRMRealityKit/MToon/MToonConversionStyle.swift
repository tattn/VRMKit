import VRMKitRuntime

/// How a standard Unlit / PBR glTF material converts into MToon when a renderer
/// is asked to toon-shade a model that carries no MToon data of its own.
public struct MToonConversionStyle: Sendable {
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
    /// the shadowed side keeps the material's hue.
    public var shadeColorScale: Float
    /// 0...1; higher values sharpen the boundary between the lit and shaded sides.
    public var shadingToonyFactor: Float
    /// Shifts where the lit-shade boundary sits; 0 keeps the MToon default.
    public var shadingShiftFactor: Float
    /// How ``outlineWidthFactor`` is measured; irrelevant while it is 0.
    public var outlineWidthMode: MToonOutlineWidthMode
    /// Width of the inverted-hull outline, measured per ``outlineWidthMode``:
    /// meters for `.worldCoordinates`, a fraction of the screen height for
    /// `.screenCoordinates`. 0 draws no outline.
    public var outlineWidthFactor: Float
    public var outlineColorFactor: SIMD4<Float>

    public init(shadeColorScale: Float = MToonConversionStyle.defaultStyle.shadeColorScale,
                shadingToonyFactor: Float = MToonConversionStyle.defaultStyle.shadingToonyFactor,
                shadingShiftFactor: Float = MToonConversionStyle.defaultStyle.shadingShiftFactor,
                outlineWidthMode: MToonOutlineWidthMode = MToonConversionStyle.defaultStyle.outlineWidthMode,
                outlineWidthFactor: Float = MToonConversionStyle.defaultStyle.outlineWidthFactor,
                outlineColorFactor: SIMD4<Float> = MToonConversionStyle.defaultStyle.outlineColorFactor) {
        self.shadeColorScale = shadeColorScale
        self.shadingToonyFactor = shadingToonyFactor
        self.shadingShiftFactor = shadingShiftFactor
        self.outlineWidthMode = outlineWidthMode
        self.outlineWidthFactor = outlineWidthFactor
        self.outlineColorFactor = outlineColorFactor
    }
}
