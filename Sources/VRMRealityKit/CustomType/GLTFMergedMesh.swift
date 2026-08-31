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

/// Everything a merged model entity redraws itself from: which part each material
/// slot owns, what a first-person camera cuts of it, and the mesh variants already
/// generated. Hidden slots and first-person cuts are baked into a variant rather
/// than drawn by entities of their own, which is what keeps one mesh at one entity.
///
/// One catalog is shared by every clone of its template, so each variant is
/// generated once per document however many entity graphs show it.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class GLTFMergedMeshCatalog {
    /// One material slot of the merged mesh, built from one glTF primitive.
    struct Slot {
        /// The part's id inside the full mesh's single model.
        let partID: String
        /// What a first-person camera draws of the part.
        let firstPersonMask: FirstPersonPrimitiveMask
        /// The visibility the slot was built with, which a release restores.
        let isInitiallyVisible: Bool
    }

    /// Every slot visible, in third person.
    let fullMesh: MeshResource
    let slots: [Slot]
    private let slotIndicesByPartID: [String: Int]

    private struct VariantKey: Hashable {
        let visibleSlots: [Bool]
        let isFirstPerson: Bool
    }

    /// Nil is a variant with nothing left to draw.
    private var variants: [VariantKey: MeshResource?] = [:]
    /// The regular flows use a handful of combinations; a caller walking many
    /// resets the cache rather than growing it for the document's lifetime.
    private static let maxCachedVariants = 16

    init(fullMesh: MeshResource, slots: [Slot]) {
        self.fullMesh = fullMesh
        self.slots = slots
        self.slotIndicesByPartID = Dictionary(uniqueKeysWithValues:
            slots.enumerated().map { ($0.element.partID, $0.offset) })
    }

    var initiallyVisibleSlots: [Bool] { slots.map(\.isInitiallyVisible) }

    /// Whether a first-person camera draws this mesh differently at all.
    var hasFirstPersonCut: Bool {
        slots.contains { $0.firstPersonMask != .whole }
    }

    /// The mesh drawing exactly `visibleSlots` of the parts, cut for a
    /// first-person camera when asked, or nil when nothing is left to draw.
    func mesh(visibleSlots: [Bool], isFirstPerson: Bool) throws -> MeshResource? {
        // The first-person flag only matters where a cut exists.
        let key = VariantKey(visibleSlots: visibleSlots,
                             isFirstPerson: isFirstPerson && hasFirstPersonCut)
        if !key.isFirstPerson, !key.visibleSlots.contains(false) { return fullMesh }
        if let cached = variants[key] { return cached }

        let variant = try generateVariant(for: key)
        if variants.count >= Self.maxCachedVariants {
            variants.removeAll(keepingCapacity: true)
        }
        variants[key] = variant
        return variant
    }

    /// The full mesh's contents with the hidden and cut parts taken out, generated
    /// as a resource of its own. Part and model ids survive, so the materials and
    /// the skeletal pose keep addressing the result.
    private func generateVariant(for key: VariantKey) throws -> MeshResource? {
        var contents = fullMesh.contents
        var models = MeshModelCollection()
        for model in contents.models {
            var parts: [MeshResource.Part] = []
            for part in model.parts {
                guard let slotIndex = slotIndicesByPartID[part.id] else {
                    // A part no slot owns is kept whole: silently losing geometry
                    // would be worse than drawing it in every variant.
                    parts.append(part)
                    continue
                }
                guard key.visibleSlots[safe: slotIndex] ?? true else { continue }
                var part = part
                if key.isFirstPerson {
                    switch slots[slotIndex].firstPersonMask {
                    case .whole:
                        break
                    case .nothing:
                        continue
                    case .triangles(let indices):
                        part.triangleIndices = MeshBuffer(indices)
                    }
                }
                parts.append(part)
            }
            guard !parts.isEmpty else { continue }
            _ = models.insert(MeshResource.Model(id: model.id, parts: parts))
        }
        guard !models.isEmpty else { return nil }
        contents.models = models
        return try MeshResource.generate(from: contents)
    }
}

/// The merged-mesh state one model entity currently draws: its catalog, which
/// slots are visible, and whether a first-person camera looks at it.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFMergedMeshComponent: Component {
    let catalog: GLTFMergedMeshCatalog
    var visibleSlots: [Bool]
    var isFirstPerson = false
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
        let initial = merged.catalog.initiallyVisibleSlots
        guard merged.visibleSlots != initial else { return }
        merged.visibleSlots = initial
        applyMergedMesh(merged)
    }

    /// The visibility one slot was built with, which a released override falls back to.
    func initialMergedSlotVisibility(at slot: Int) -> Bool {
        mergedMesh?.catalog.slots[safe: slot]?.isInitiallyVisible ?? true
    }

    /// Draws the mesh as `mode`'s camera sees it, cutting the parts the head draws.
    func setMergedFirstPerson(_ isFirstPerson: Bool) {
        guard var merged = mergedMesh, merged.isFirstPerson != isFirstPerson else { return }
        merged.isFirstPerson = isFirstPerson
        applyMergedMesh(merged)
    }

    /// Regenerates the mesh for the state the component holds, for a template
    /// whose slots do not all start visible.
    func applyMergedMesh() {
        guard let merged = mergedMesh else { return }
        applyMergedMesh(merged)
    }

    private func applyMergedMesh(_ merged: GLTFMergedMeshComponent) {
        let mesh: MeshResource?
        do {
            mesh = try merged.catalog.mesh(visibleSlots: merged.visibleSlots,
                                           isFirstPerson: merged.isFirstPerson)
        } catch {
            // The component keeps describing what is drawn, so the caller's next
            // attempt is not swallowed by the did-anything-change guards.
            GLTFResourceCache.gltfLogger.error("Failed to generate a mesh variant: \(String(describing: error), privacy: .public)")
            return
        }
        components.set(merged)
        // A variant with nothing to draw hides the entity instead of drawing an
        // empty mesh; the last mesh stays for the state that shows it again.
        isEnabled = mesh != nil
        guard let mesh, var model = components[ModelComponent.self], model.mesh !== mesh else { return }
        model.mesh = mesh
        components.set(model)
        refreshBlendShapes(for: mesh)
        owningGLTFEntity?.didSwapMeshVariant()
    }

    /// The model this entity is drawn as part of, which counts the mesh variants
    /// swapped in under it.
    private var owningGLTFEntity: GLTFEntity? {
        sequence(first: self, next: \.parent).lazy.compactMap { $0 as? GLTFEntity }.first
    }

    /// A fresh weights component for the swapped-in mesh, carrying the weights the
    /// old one held: variants drop parts, so the weight sets are laid out anew.
    private func refreshBlendShapes(for mesh: MeshResource) {
        guard components.has(BlendShapeWeightsComponent.self) else { return }
        let weights = blendWeights.first
        let mapping = BlendShapeWeightsMapping(meshResource: mesh)
        components.set(BlendShapeWeightsComponent(weightsMapping: mapping))
        if let weights, weights.contains(where: { $0 != 0 }) {
            applyMorphWeights(weights)
        }
    }
}
#endif
