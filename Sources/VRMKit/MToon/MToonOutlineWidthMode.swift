import Foundation

/// How the width of MToon's inverted-hull outline is measured, as
/// `VRMC_materials_mtoon` writes it.
///
/// One enum serves the whole path a value takes: the material it is decoded
/// from, the model it is read into, the conversion that synthesizes it, and the
/// renderer that draws it.
public enum MToonOutlineWidthMode: String, Codable, Sendable {
    /// No outline, whatever width the material carries.
    case none
    /// Meters of world space, so the outline thickens on screen as the camera
    /// nears it.
    case worldCoordinates
    /// A fraction of the screen height, so the outline keeps one on-screen
    /// thickness at any distance.
    case screenCoordinates
}
