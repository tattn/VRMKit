#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKitRuntime

/// The glTF materials a merged model entity renders, by material slot: entry `i`
/// names the glTF material behind `ModelComponent.materials[i]`. Nil is a
/// primitive that names no material and renders the default one.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFMaterialSlotsComponent: Component {
    let materialIndices: [Int?]
}

/// The merged-mesh state one model entity currently draws: which of its material
/// slots are visible, which a caller draws instead of RealityKit, and whether a
/// first-person camera looks at it. Hidden slots and first-person cuts are a choice
/// of parts over the one mesh rather than entities of their own, which is what keeps
/// one mesh at one entity.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFMergedMeshComponent: Component {
    /// The visibility each slot was built with, which a release restores.
    let initiallyVisibleSlots: [Bool]
    var visibleSlots: [Bool]
    /// Visible slots RealityKit leaves to a caller that draws them itself.
    var callerDrawnSlots: Set<Int> = []
    var isFirstPerson = false

    init(initiallyVisibleSlots: [Bool]) {
        self.initiallyVisibleSlots = initiallyVisibleSlots
        visibleSlots = initiallyVisibleSlots
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension ModelEntity {
    var mergedMesh: GLTFMergedMeshComponent? {
        components[GLTFMergedMeshComponent.self]
    }

    /// Shows or hides the given material slots, redrawing the mesh without the
    /// hidden parts so they issue no draw call. An entity built without a merged
    /// mesh toggles whole, as visibility without slots means.
    func setMergedSlotVisibility(_ isVisible: Bool, slots slotIndices: some Sequence<Int>) {
        guard var merged = mergedMesh else {
            isEnabled = isVisible
            return
        }
        var changed = false
        for slot in slotIndices where merged.visibleSlots.indices.contains(slot)
            && merged.visibleSlots[slot] != isVisible {
            merged.visibleSlots[slot] = isVisible
            changed = true
        }
        guard changed else { return }
        applyMergedMesh(merged)
    }

    /// ``setMergedSlotVisibility(_:slots:)`` over every slot.
    func setMergedVisibility(_ isVisible: Bool) {
        setMergedSlotVisibility(isVisible, slots: mergedMesh?.visibleSlots.indices ?? 0..<0)
    }

    /// Puts every slot back to the visibility it was built with.
    func resetMergedVisibility() {
        guard var merged = mergedMesh else { return }
        guard merged.visibleSlots != merged.initiallyVisibleSlots else { return }
        merged.visibleSlots = merged.initiallyVisibleSlots
        applyMergedMesh(merged)
    }

    func initialMergedSlotVisibility(at slot: Int) -> Bool {
        mergedMesh?.initiallyVisibleSlots[safe: slot] ?? true
    }

    /// Leaves the given material slots to a caller that draws them itself, or takes them back.
    /// Whether a slot is visible stays as it is.
    func setMergedSlotsDrawnByCaller(_ isDrawnByCaller: Bool, slots slotIndices: some Sequence<Int>) {
        guard var merged = mergedMesh else { return }
        let callerDrawnSlots = isDrawnByCaller
            ? merged.callerDrawnSlots.union(slotIndices)
            : merged.callerDrawnSlots.subtracting(slotIndices)
        guard callerDrawnSlots != merged.callerDrawnSlots else { return }
        merged.callerDrawnSlots = callerDrawnSlots
        applyMergedMesh(merged)
    }

    /// Draws the mesh as a first- or third-person camera sees it, cutting the parts the head draws.
    func setMergedFirstPerson(_ isFirstPerson: Bool) {
        guard var merged = mergedMesh, merged.isFirstPerson != isFirstPerson else { return }
        merged.isFirstPerson = isFirstPerson
        applyMergedMesh(merged)
    }

    /// Draws the parts the state the component holds describes.
    func applyMergedMesh() {
        guard let merged = mergedMesh else { return }
        applyMergedMesh(merged)
    }

    private func applyMergedMesh(_ merged: GLTFMergedMeshComponent) {
        components.set(merged)
        guard let deformedMesh else { return }
        // A state with nothing to draw hides the entity instead of drawing an empty
        // mesh; the last parts stay for the state that shows it again.
        isEnabled = deformedMesh.setParts(visibleSlots: merged.visibleSlots,
                                          callerDrawnSlots: merged.callerDrawnSlots,
                                          isFirstPerson: merged.isFirstPerson)
    }
}
#endif
