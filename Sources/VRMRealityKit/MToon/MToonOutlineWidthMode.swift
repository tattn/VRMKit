import VRMKitRuntime

/// How the width of MToon's inverted-hull outline is measured, mirroring the
/// `outlineWidthMode` values of `VRMC_materials_mtoon` that draw an outline.
public enum MToonOutlineWidthMode: Sendable {
    /// Meters of world space, so the outline thickens on screen as the camera
    /// nears it.
    case worldCoordinates
    /// A fraction of the screen height, so the outline keeps one on-screen
    /// thickness at any distance.
    case screenCoordinates
}

extension MToonOutlineWidthMode {
    var descriptorMode: MToonMaterialDescriptor.OutlineWidthMode {
        switch self {
        case .worldCoordinates: return .worldCoordinates
        case .screenCoordinates: return .screenCoordinates
        }
    }
}
