#if canImport(RealityKit)
import Foundation

/// Selects how VRMRealityKit builds MToon materials for a given host environment.
///
/// Use ``VRMRenderingMode/nonAR`` for offline previews and non-AR `ARView` hosts such as the
/// bundled Examples. Use ``VRMRenderingMode/ar`` when placing models in a live AR session.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public enum VRMRenderingMode: Sendable {
    /// Non-AR preview (Example apps). Full MToon rendering including geometry modifiers and outlines.
    case nonAR
    /// Live AR session. Uses surface-only CustomMaterial (no geometry modifier, no outline)
    /// with shadow casting disabled on all model entities. Requires the host app to call
    /// ``VRMEntity/update(at:)`` each frame and optionally ``VRMEntity/setMToonLightDirection(_:)``.
    /// The host `ARView` should set `renderOptions.insert(.disableGroundingShadows)`.
    case ar
}
#endif
