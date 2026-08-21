import VRMKitRuntime

/// How a standard Unlit / PBR glTF material converts into MToon when a renderer
/// is asked to toon-shade a model that carries no MToon data of its own.
public struct MToonConversionStyle: Sendable {
    /// The canonical conversion style. Its MToon values come directly from the
    /// specification defaults shared with authored MToon materials.
    public static let defaultStyle = MToonConversionStyle(
        shadeColorScale: 0.8,
        shadingToonyFactor: MToonMaterialDescriptor.SpecDefault.shadingToonyFactor,
        shadingShiftFactor: MToonMaterialDescriptor.SpecDefault.shadingShiftFactor,
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
    /// Width of the inverted-hull outline in meters; 0 draws no outline.
    public var outlineWidthFactor: Float
    public var outlineColorFactor: SIMD4<Float>

    public init(shadeColorScale: Float = MToonConversionStyle.defaultStyle.shadeColorScale,
                shadingToonyFactor: Float = MToonConversionStyle.defaultStyle.shadingToonyFactor,
                shadingShiftFactor: Float = MToonConversionStyle.defaultStyle.shadingShiftFactor,
                outlineWidthFactor: Float = MToonConversionStyle.defaultStyle.outlineWidthFactor,
                outlineColorFactor: SIMD4<Float> = MToonConversionStyle.defaultStyle.outlineColorFactor) {
        self.shadeColorScale = shadeColorScale
        self.shadingToonyFactor = shadingToonyFactor
        self.shadingShiftFactor = shadingShiftFactor
        self.outlineWidthFactor = outlineWidthFactor
        self.outlineColorFactor = outlineColorFactor
    }
}
