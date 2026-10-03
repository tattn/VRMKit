#if canImport(RealityKit)
import RealityKit
import simd

/// The MToon runtime of a loaded entity, on ``GLTFEntity`` because a plain glTF renders as
/// MToon too through ``MToonShader/Source/convertAll(_:)``. A plain `clone(recursive:)` keeps
/// drawing as its original does; ``GLTFEntity/cloneWithOwnMaterialParameters()`` gets its own.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFEntity {
    // MARK: - Lighting

    /// Sets the light direction, color and ambient color with one write per material, for a
    /// caller tracking a light per frame.
    ///
    /// `direction` points from the surface toward the light, so a matching `DirectionalLight`
    /// sits at `direction` and aims at the model. The defaults are a white light and a black
    /// ambient, which feeds the MToon GI approximation.
    public func setMToonLighting(direction: SIMD3<Float>, color: SIMD3<Float>, ambient: SIMD3<Float>) {
        let normalized = Self.normalizedMToonLightDirection(direction)
        updateMaterialStates(MToonAnimatableMaterialState.self) { state in
            let directionChanged = state.setLightDirection(normalized)
            let colorChanged = state.setLightColor(color)
            let ambientChanged = state.setAmbientColor(ambient)
            return directionChanged || colorChanged || ambientChanged
        }
    }

    /// See ``setMToonLighting(direction:color:ambient:)``.
    public func setMToonLightDirection(_ direction: SIMD3<Float>) {
        let normalized = Self.normalizedMToonLightDirection(direction)
        updateMaterialStates(MToonAnimatableMaterialState.self) { $0.setLightDirection(normalized) }
    }

    /// See ``setMToonLighting(direction:color:ambient:)``.
    public func setMToonLightColor(_ color: SIMD3<Float>) {
        updateMaterialStates(MToonAnimatableMaterialState.self) { $0.setLightColor(color) }
    }

    /// See ``setMToonLighting(direction:color:ambient:)``.
    public func setMToonAmbientColor(_ color: SIMD3<Float>) {
        updateMaterialStates(MToonAnimatableMaterialState.self) { $0.setAmbientColor(color) }
    }

    private static func normalizedMToonLightDirection(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(direction)
        return length > 0.001 ? direction / length : MToonMaterialParameters.defaultLightDirection
    }
}
#endif
