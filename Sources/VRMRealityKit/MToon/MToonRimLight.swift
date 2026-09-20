import simd

/// A rim light the runtime adds on top of a model's authored MToon: light from
/// `direction` that lines the silhouette facing it, like a backlight.
///
/// MToon's own parametric rim depends on the view alone, so it cannot say which
/// side the light comes from. This term is independent of it; the rim-multiply
/// texture masks both. The shape follows the backlight of anime-style shaders: a
/// band of set width along the silhouette rather than a Fresnel gradient.
public struct MToonRimLight: Sendable, Equatable {
    /// Linear RGB. Values above 1 are allowed, for a renderer with bloom.
    public var color: SIMD3<Float>
    /// From the surface toward the light, in the space the model's light
    /// direction is given in. A backlight has it pointing away from the viewer.
    public var direction: SIMD3<Float>
    /// How far in from the silhouette the band reaches, 0 to 1. 1 covers every
    /// surface the light reaches; 0.3 is a thin outline.
    public var width: Float
    /// How soft the band's inner edge is, 0 to 1. 0 is a hard anime edge.
    public var softness: Float
    /// How far around the shadowed side the band continues, 0 to 1. At 0 it stops
    /// where the surface turns away from the light; at 1 it lines the whole
    /// silhouette regardless.
    public var wrap: Float
    /// How much the light is bent away from the viewer, 0 to 1. A backlight
    /// aimed at the model still lines the near edges with this above 0.
    public var viewBend: Float
    /// How the band meets the surface, 0 to 1. At 0 the light adds to the lit
    /// color, which a bright surface swallows; at 1 the band is painted in the
    /// rim's color over it, the way an illustration draws a rim on white cloth.
    public var blend: Float

    public init(color: SIMD3<Float>,
                direction: SIMD3<Float>,
                width: Float = 0.3,
                softness: Float = 0.1,
                wrap: Float = 0.5,
                viewBend: Float = 0.5,
                blend: Float = 0) {
        self.color = color
        self.direction = direction
        self.width = width
        self.softness = softness
        self.wrap = wrap
        self.viewBend = viewBend
        self.blend = blend
    }

    var normalizedDirection: SIMD3<Float> {
        let length = simd_length(direction)
        return length > 0.001 ? direction / length : SIMD3<Float>(0, 0, 1)
    }
}
