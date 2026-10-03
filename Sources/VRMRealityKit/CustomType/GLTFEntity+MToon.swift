#if canImport(RealityKit)
import RealityKit
import simd

/// The MToon runtime of a loaded entity. It lives here rather than on
/// ``VRMEntity`` because MToon is a material extension a plain glTF can render
/// too, through ``MToonShader/Source/convertAll(_:)``.
///
/// The setters act on a loaded entity or a ``GLTFEntity/cloneWithOwnMaterialParameters()``
/// copy; a plain `clone(recursive:)` keeps drawing as its original does.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFEntity {
    /// The MToon parameter rows a material renders with, or nil when it does
    /// not render as MToon.
    func mtoonParameters(forMaterialIndex index: Int) -> MToonMaterialParameters? {
        mtoonState(forMaterialIndex: index)?.parameters
    }

    func mtoonState(forMaterialIndex index: Int) -> MToonAnimatableMaterialState? {
        materialState(MToonAnimatableMaterialState.self, ofMaterial: index)
    }

    // MARK: - Lighting

    /// Sets the light direction, light color and ambient color together, pushing the
    /// rows to the GPU once. A caller tracking a light per frame (a device that moves,
    /// a background whose light is re-estimated) goes through here rather than the
    /// three setters, which would flush every material three times a frame.
    ///
    /// The vector points from the surface toward the light, so a `DirectionalLight`
    /// matching it sits at `direction` and aims at the model. The default color is
    /// white and the default ambient color, feeding the MToon GI approximation, black.
    public func setMToonLighting(direction: SIMD3<Float>, color: SIMD3<Float>, ambient: SIMD3<Float>) {
        let normalized = Self.normalizedMToonLightDirection(direction)
        updateMaterialStates(MToonAnimatableMaterialState.self) { state in
            let directionChanged = state.setLightDirection(normalized)
            let colorChanged = state.setLightColor(color)
            let ambientChanged = state.setAmbientColor(ambient)
            return directionChanged || colorChanged || ambientChanged
        }
    }

    /// The vector points from the surface toward the light, so a `DirectionalLight`
    /// matching it sits at `direction` and aims at the model. It rides in the parameter
    /// texture, so tracking a light per frame is one small blit per material.
    public func setMToonLightDirection(_ direction: SIMD3<Float>) {
        let normalized = Self.normalizedMToonLightDirection(direction)
        updateMaterialStates(MToonAnimatableMaterialState.self) { $0.setLightDirection(normalized) }
    }

    /// The default is white.
    public func setMToonLightColor(_ color: SIMD3<Float>) {
        updateMaterialStates(MToonAnimatableMaterialState.self) { $0.setLightColor(color) }
    }

    /// Feeds the MToon GI approximation. The default is black.
    public func setMToonAmbientColor(_ color: SIMD3<Float>) {
        updateMaterialStates(MToonAnimatableMaterialState.self) { $0.setAmbientColor(color) }
    }

    private static func normalizedMToonLightDirection(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(direction)
        return length > 0.001 ? direction / length : MToonMaterialParameters.defaultLightDirection
    }
}
#endif
