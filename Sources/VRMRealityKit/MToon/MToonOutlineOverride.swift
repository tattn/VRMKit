import simd
import VRMKit

/// An outline drawn in place of the one a model was authored with, for as long
/// as it is set, a selection highlight being the case it exists for.
///
/// It reaches every material that has an outline pass, including those whose own
/// MToon data draws none, which ``MToonShader/OutlinePass/always`` builds for.
public struct MToonOutlineOverride: Sendable, Equatable {
    /// Linear RGB. MToon takes an outline's opacity from the material it
    /// outlines, so an override carries no alpha.
    public var color: SIMD3<Float>
    /// Meters for ``MToonOutlineWidthMode/worldCoordinates``, a fraction of the
    /// screen height for ``MToonOutlineWidthMode/screenCoordinates``. Zero or
    /// less outlines nothing, as does ``MToonOutlineWidthMode/none``: the
    /// passes are hidden rather than shown.
    public var width: Float
    public var mode: MToonOutlineWidthMode

    public init(color: SIMD3<Float>,
                width: Float,
                mode: MToonOutlineWidthMode = .screenCoordinates) {
        self.color = color
        self.width = width
        self.mode = mode
    }
}
