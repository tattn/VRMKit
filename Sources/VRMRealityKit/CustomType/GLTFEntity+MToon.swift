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

    /// The vector points from the surface toward the light, so a
    /// `DirectionalLight` matching it sits at `direction` and aims at the model.
    public func setMToonLightDirection(_ direction: SIMD3<Float>) {
        let length = simd_length(direction)
        let normalized = length > 0.001 ? direction / length : MToonMaterialParameters.defaultLightDirection
        guard simd_distance(normalized, mtoonLightDirection) > 0.0001 else { return }
        mtoonLightDirection = normalized
        // The direction rides in custom.value rather than in a parameter row, so
        // it reaches the materials without rebuilding their packed texture, and
        // without clearing a rebuild an earlier row change is still waiting for.
        for materialIndex in materialStates.keys {
            guard let state = mtoonState(forMaterialIndex: materialIndex) else { continue }
            state.setLightDirection(normalized)
            mapMaterials(ofMaterial: materialIndex) { state.applyLightDirection(to: $0) }
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

    private func updateMToonLightingRows() {
        mutateMToonStates { state in
            state.setLighting(color: mtoonLightColor, ambient: mtoonAmbientColor)
            return true
        }
    }

    // MARK: - Outline

    /// Draws every outline with `override`, showing the passes that start
    /// hidden. Which materials have a pass at all is fixed at load by
    /// ``MToonShader/OutlinePass``. A zero ``MToonOutlineOverride/width``
    /// outlines nothing, so it hides the passes instead.
    ///
    /// Passing nil puts the model back as it was: authored colors and widths,
    /// and the pass visibility from before the override — a
    /// ``GLTFEntity/setPassEnabled(_:named:)`` of the caller's own included. A
    /// VRM `materialColorBind` expression drives the color underneath meanwhile,
    /// so releasing reveals its current value.
    ///
    /// Setting the same override again re-asserts it, which is how a set whose
    /// rows could not be baked is retried. On a `clone(recursive:)` copy, which
    /// carries no material runtime, the whole call is a no-op.
    ///
    /// This is ``setMToonOutlineOverride(_:forMaterials:)`` over every
    /// material, so a nil here releases scoped overrides too.
    public func setMToonOutlineOverride(_ override: MToonOutlineOverride?) {
        setMToonOutlineOverride(override, forMaterials: Set(materialStates.keys))
    }

    /// ``setMToonOutlineOverride(_:)`` restricted to `materials`, which
    /// ``GLTFEntity/materialIndices(under:)`` supplies for a node's subtree.
    ///
    /// The unit is the glTF material: one shared beyond the selection is
    /// outlined everywhere it draws, as glTF shares materials. Materials
    /// outside the set keep whatever override they hold, so selections
    /// compose; within it the last set wins per material, and releasing
    /// restores what that material's first covering set replaced. Materials
    /// with no outline pass, or not rendered as MToon, are left alone.
    public func setMToonOutlineOverride(_ override: MToonOutlineOverride?,
                                        forMaterials materials: Set<Int>) {
        let isDrawn = mutateMToonStates(inPassNamed: MToonShader.outlinePassName,
                                        forMaterials: materials) { state in
            guard state.outlineOverride != override else { return false }
            state.outlineOverride = override
            return true
        }
        // The visibility follows what the GPU draws, not what the rows say:
        // showing a pass early would draw whatever is underneath the override —
        // nothing at all, for a material `.always` built an empty pass for — and
        // hiding one early would take away an outline still being drawn.
        guard isDrawn else { return }
        if let override {
            // The inverted hull's surface draws wherever its geometry does, even
            // un-offset, so a zero-width outline must not issue the pass at all:
            // on an open mesh it would paint back faces in the outline color.
            overridePassEnabled(override.width > 0,
                                named: MToonShader.outlinePassName,
                                forMaterials: materials)
        } else {
            releasePassEnabledOverride(named: MToonShader.outlinePassName, forMaterials: materials)
        }
    }

    /// Edits every MToon material's parameter rows and pushes the result to the
    /// GPU once per material. Naming a pass restricts the edit to materials that
    /// draw it, so rows nothing samples are not rebaked; giving a material set
    /// restricts it further to those materials. `mutate` reports whether it
    /// changed anything, so writing the values already in place rebakes
    /// nothing either.
    ///
    /// Returns whether the materials it covers are drawn as their rows now
    /// stand: false when there are none, as on a `clone(recursive:)` copy, and
    /// false while a parameter texture that failed to bake keeps its material
    /// dirty for the next flush to retry.
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
