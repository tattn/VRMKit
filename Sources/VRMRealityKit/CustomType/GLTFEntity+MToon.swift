#if canImport(RealityKit)
import RealityKit
import simd

/// The MToon runtime of a loaded entity. It lives here rather than on
/// ``VRMEntity`` because MToon is a material extension a plain glTF can render
/// too, through ``MToonShader/Source/convertAll(_:)``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFEntity {
    /// The MToon parameter rows a material renders with, or nil when it does
    /// not render as MToon.
    func mtoonParameters(forMaterialIndex index: Int) -> MToonMaterialParameters? {
        mtoonState(forMaterialIndex: index)?.parameters
    }

    func mtoonState(forMaterialIndex index: Int) -> MToonAnimatableMaterialState? {
        materialStates[index]?.animatable as? MToonAnimatableMaterialState
    }

    // MARK: - Lighting

    /// The vector points from the surface toward the light, so a `DirectionalLight`
    /// matching it sits at `direction` and aims at the model. It rides in the parameter
    /// texture, so tracking a light per frame is one small blit per material.
    public func setMToonLightDirection(_ direction: SIMD3<Float>) {
        let length = simd_length(direction)
        let normalized = length > 0.001 ? direction / length : MToonMaterialParameters.defaultLightDirection
        guard simd_distance(normalized, mtoonLightDirection) > 0.0001 else { return }
        mtoonLightDirection = normalized
        mutateMToonStates { state in
            state.setLightDirection(normalized)
            return true
        }
    }

    /// The default is white.
    public func setMToonLightColor(_ color: SIMD3<Float>) {
        guard color != mtoonLightColor else { return }
        mtoonLightColor = color
        updateMToonLightingRows()
    }

    /// Feeds the MToon GI approximation. The default is black.
    public func setMToonAmbientColor(_ color: SIMD3<Float>) {
        guard color != mtoonAmbientColor else { return }
        mtoonAmbientColor = color
        updateMToonLightingRows()
    }

    /// Blocks until every MToon parameter write has reached the GPU, for a
    /// caller about to render on another queue: the snapshot.
    func waitForMToonParameterWrites() {
        for index in materialStates.keys {
            mtoonState(forMaterialIndex: index)?.waitForParameterWrites()
        }
    }

    private func updateMToonLightingRows() {
        mutateMToonStates { state in
            state.setLighting(color: mtoonLightColor, ambient: mtoonAmbientColor)
            return true
        }
    }

    // MARK: - Outline

    /// Draws every outline with `override`, showing the passes that start hidden. Which
    /// materials have a pass at all is fixed at load by ``MToonShader/OutlinePass``, and a
    /// zero ``MToonOutlineOverride/width`` hides the passes instead.
    ///
    /// Passing nil puts the model back to its authored colors, widths and pass visibility.
    /// Setting the same override again re-asserts it, retrying a set whose rows could not
    /// be baked. This is ``setMToonOutlineOverride(_:forMaterials:)`` over every material,
    /// so a nil here releases scoped overrides too.
    public func setMToonOutlineOverride(_ override: MToonOutlineOverride?) {
        setMToonOutlineOverride(override, forMaterials: Set(materialStates.keys))
    }

    /// ``setMToonOutlineOverride(_:)`` restricted to `materials`, which
    /// ``GLTFEntity/materialIndices(under:)`` supplies for a node's subtree.
    ///
    /// The unit is the glTF material, so one shared beyond the selection is outlined
    /// everywhere it draws, and the last set wins per material.
    public func setMToonOutlineOverride(_ override: MToonOutlineOverride?,
                                        forMaterials materials: Set<Int>) {
        let isDrawn = mutateMToonStates(inPassNamed: MToonShader.outlinePassName,
                                        forMaterials: materials) { state in
            guard state.outlineOverride != override else { return false }
            state.outlineOverride = override
            return true
        }
        // The visibility follows what the GPU draws, not what the rows say:
        // showing or hiding a pass early would draw the wrong thing for a frame.
        guard isDrawn else { return }
        if let override {
            // The inverted hull draws wherever its geometry does, even un-offset,
            // so a zero-width outline must not issue the pass at all.
            overridePassEnabled(override.width > 0,
                                named: MToonShader.outlinePassName,
                                forMaterials: materials)
        } else {
            releasePassEnabledOverride(named: MToonShader.outlinePassName, forMaterials: materials)
        }
    }

    /// Edits every MToon material's parameter rows and pushes the result to the GPU once
    /// per material. A pass name and a material set each narrow what is edited, and
    /// `mutate` reports whether it changed anything, so rewriting values rebakes nothing.
    ///
    /// Returns whether the materials it covers are drawn as their rows now stand: false
    /// when there are none, and false while a texture that failed to bake stays dirty.
    @discardableResult
    private func mutateMToonStates(inPassNamed passName: String? = nil,
                                   forMaterials materials: Set<Int>? = nil,
                                   _ mutate: (MToonAnimatableMaterialState) -> Bool) -> Bool {
        var foundState = false
        for (index, materialState) in materialStates {
            if let materials, !materials.contains(index) { continue }
            guard let state = materialState.animatable as? MToonAnimatableMaterialState else { continue }
            if let passName, !materialState.hasPass(named: passName) { continue }
            foundState = true
            if mutate(state) {
                materialStates[index]?.needsFlush = true
            }
        }
        return flushDirtyMaterialStates() && foundState
    }
}
#endif
