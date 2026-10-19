#if canImport(RealityKit)
import Foundation
import Metal
import OSLog
import RealityKit
import simd
import VRMKit

/// Carries the loaded document on the entity, so `clone(recursive:)` copies still
/// answer ``GLTFEntity/document``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFComponent: Component {
    let document: GLTFDocument
    let sceneIndex: Int
    let outputColorSpace: GLTFOutputColorSpace
}

/// The glTF node a loaded entity was built from, identified by array index:
/// `name` is optional and may repeat.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFNodeComponent: Component {
    public let nodeIndex: Int
}

/// Marks a model entity as an additional render pass of its glTF materials, such as
/// MToon's inverted-hull outline, rather than the materials themselves. What each
/// slot starts showing lives in the entity's ``GLTFMergedMeshComponent``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFMaterialPassComponent: Component {
    public let name: String
}

/// The triangles of one material in one deformed mesh, as ``GLTFEntity/geometry(ofMaterial:)`` returns them.
/// The vertices are in `modelEntity`'s space, in the mesh's vertex buffers as its descriptor
/// lays them out, and `materialSlot` is the material's place in `modelEntity`'s `ModelComponent`,
/// whose material says the rest of how it draws, such as its face culling and depth writes.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFMaterialGeometry {
    public let modelEntity: ModelEntity
    /// The ``GLTFShadedMaterial/Pass/name`` of an additional render pass, such as MToon's
    /// outline, or nil for the material itself.
    public let passName: String?
    public let materialSlot: Int
    public let mesh: LowLevelMesh
    /// How the material cuts out or blends as the loader draws it, which can differ from the
    /// document: a MASK material that would discard nothing draws `.OPAQUE`.
    public let alphaMode: GLTF.Material.AlphaMode
    /// Where a blended material draws among the blended materials, lower first, as
    /// ``GLTFShadedMaterial/renderQueue`` says. Nil unless blended.
    public let renderQueue: Int?
    let slot: GLTFMeshGeometry.Slot

    /// The triangles drawn now, counted in the mesh's `UInt32` indices: without those a
    /// first-person camera cuts, while ``VRMEntity/setFirstPersonRenderMode(_:)`` asks for it.
    @MainActor
    public var indexRange: Range<Int> {
        slot.indexRange(isFirstPerson: modelEntity.mergedMesh?.isFirstPerson ?? false)
    }

    /// Whether the triangles show now: the pass is enabled
    /// (``GLTFEntity/setPassEnabled(_:named:forMaterials:)``), something is left after a
    /// first-person cut, and the mesh's entity is enabled. The model entity itself is disabled
    /// while RealityKit draws nothing of it, as when every slot is drawn by the caller.
    @MainActor
    public var isVisible: Bool {
        (modelEntity.mergedMesh?.visibleSlots[safe: materialSlot] ?? true)
            && !indexRange.isEmpty
            && modelEntity.parent?.isEnabledInHierarchy == true
    }
}

/// The glTF skin a model entity is skinned by. It survives `clone(recursive:)`, so a
/// mesh built once and cloned per node still binds its own joints.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFSkinIndexComponent: Component {
    let skinIndex: Int
}

/// The root entity of a loaded glTF scene.
///
/// Besides the entity graph it keeps what the animation runtime binds against: the
/// document, the node index to `Entity` mapping, the skin and morph bindings, and
/// the render state of each glTF material.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public class GLTFEntity: Entity {
    /// The glTF document this entity was loaded from.
    ///
    /// - Precondition: the entity came from a ``GLTFEntityLoader``, not from
    ///   ``init()``.
    public var document: GLTFDocument {
        guard let document = components[GLTFComponent.self]?.document else {
            preconditionFailure("This GLTFEntity carries no document. Load it with GLTFEntityLoader.")
        }
        return document
    }

    public var gltf: GLTF {
        document.gltf
    }

    /// Index into `gltf.scenes` this entity graph was built from.
    public var sceneIndex: Int {
        guard let index = components[GLTFComponent.self]?.sceneIndex else {
            preconditionFailure("This GLTFEntity carries no document. Load it with GLTFEntityLoader.")
        }
        return index
    }

    /// See ``GLTFEntityLoader/outputColorSpace``.
    var outputColorSpace: GLTFOutputColorSpace {
        components[GLTFComponent.self]?.outputColorSpace ?? .displayP3
    }

    /// glTF node index → the entity built for it, for this scene.
    private var nodeEntities: [Entity?]?

    /// Every node transform of the model, which the runtimes pose and skinning reads (see
    /// ``GLTFPose``). Nil on a `clone(recursive:)` copy, which has no runtime.
    ///
    /// Write a node here rather than to its entity: the entity is a copy of it, kept as
    /// ``nodeEntitySynchronization`` says.
    public private(set) var pose: GLTFPose?

    /// Which node entities stay a copy of ``pose``. Every one by default, so code that reads
    /// a node entity, or hangs something under it, sees the pose. Narrowing it saves the
    /// renderer's work per node written, which is most of what posing a model costs.
    public var nodeEntitySynchronization: GLTFNodeEntitySynchronization = .all {
        didSet {
            guard nodeEntitySynchronization != oldValue else { return }
            synchronizedNodes = nil
            pose?.handedBackNodes = nil
            synchronizeNodeEntities()
        }
    }

    /// Per node, whether its entity is kept a copy of the pose; nil until first asked.
    private var synchronizedNodes: [Bool]?

    /// Whether this entity carries the bindings the animation runtime drives. A
    /// `clone(recursive:)` copy carries none, since they would point at the original's
    /// entities: load the scene again to get one.
    public var hasRuntimeBindings: Bool { nodeEntities != nil }

    /// The entity built for the glTF node at `index`, or nil when the index is out of
    /// range or the node is not part of this scene.
    public func entity(forNodeAt index: Int) -> Entity? {
        guard let nodeEntities, nodeEntities.indices.contains(index) else { return nil }
        return nodeEntities[index]
    }

    /// The index in ``pose`` of the node `entity` was built for, or nil when it is not one of
    /// this scene's node entities.
    public func nodeIndex(of entity: Entity) -> Int? {
        guard let index = entity.components[GLTFNodeComponent.self]?.nodeIndex,
              entity === self.entity(forNodeAt: index) else { return nil }
        return index
    }

    struct SkinBinding {
        let modelEntity: ModelEntity
        /// The node each joint was built for, in the skeleton's order.
        let jointNodes: [Int]
        /// Each joint's parent in the skeleton, read off the skeleton once: the solve reads
        /// a row per joint per frame, and the skeleton hands its joints out by copy.
        let parentIndices: [Int?]
        /// The mesh the solved pose is written to.
        let deformedMesh: GLTFDeformedMesh?
    }

    /// Every mesh this entity's own document deforms, whose pending skinning and
    /// morphing ``flushDeformation()`` submits.
    private(set) var deformedMeshes: [GLTFDeformedMesh] = []

    func registerDeformedMesh(_ mesh: GLTFDeformedMesh) {
        deformedMeshes.append(mesh)
    }

    private(set) var skinBindings: [SkinBinding] = []

    /// The bindings that read one skeleton in one model space, which solve to the same rows:
    /// a mesh and its outline twin, or the render-queue groups of one mesh.
    private struct SkinSolve {
        let jointNodes: [Int]
        let parentIndices: [Int?]
        /// The node the meshes hang under, nil for the model's root, and where the meshes
        /// stand below it: a joint the skeleton gives no parent is read in the meshes' space.
        let anchorNode: Int?
        let anchorOffset: simd_float4x4
        /// An entity drawing the meshes, whose place within the model the anchor was read from.
        let anchorEntity: Entity
        var meshes: [GLTFDeformedMesh]
        var rows: [Transform] = []
        /// Rows read through the model rather than off the joint's own transform: the
        /// skeleton's roots, and joints whose skeleton parent is not their node's parent.
        /// Nodes outside the skeleton move them, so every solve re-reads them.
        var dependentRows: [Int] = []

        func isDependent(_ row: Int) -> Bool {
            dependentRows.contains(row)
        }
    }

    private var skinSolves: [SkinSolve] = []
    private var changedSkinSolves: [Bool] = []
    /// Node → every (solve, row) it poses.
    private var skinRowsByNode: [[(solve: Int, row: Int)]] = []
    /// Whether ``skinSolves`` has to be built.
    private var needsSkinSolveSetUp = true
    /// Whether a mesh entity may have moved within the model, which re-reads where each
    /// solve's meshes stand and rebuilds the solves only if one did.
    private var needsSkinAnchorCheck = false
    /// Whether the node entities were read back since the runtime last ran, so the update
    /// does not read them twice.
    private var hasAdoptedNodeEntities = false

    struct MorphBinding {
        var modelEntities: [ModelEntity]
        let targetCount: Int
    }

    /// glTF node index → the blend shapes a `weights` channel writes to.
    private(set) var morphBindings: [Int: MorphBinding] = [:]

    /// One place a glTF material is rendered: which slot of which entity's
    /// materials array holds it.
    struct MaterialBinding {
        let modelEntity: ModelEntity
        let slot: Int
    }

    /// What the runtime tracks per glTF material, so its shader parameters stay single-source.
    struct MaterialRuntimeState {
        /// Every material slot rendering the material, additional passes included.
        var bindings: [MaterialBinding] = []
        /// Present when what renders the material makes one, as MToon does.
        var animatable: (any VRMAnimatableMaterialState)?
        var needsFlush = false
        /// How the loader draws the material, which a caller drawing it itself draws it as.
        var alphaMode: GLTF.Material.AlphaMode = .OPAQUE
        var renderQueue: Int?
    }

    var materialStates: [Int: MaterialRuntimeState] = [:]

    // Backing store for the animation API in GLTFEntity+Animation.swift.
    var animationMetadata: [GLTFAnimation]?
    /// One decoder for the whole document: samplers routinely share an input accessor.
    lazy var animationDecoder = GLTFAnimationDecoder(document: document)
    private var cachedRestPose: GLTFRestPose?
    var animationRuntimes: [Int: GLTFAnimationRuntime] = [:]
    var activeAnimationControllers: [GLTFAnimationPlaybackController] = []

    /// Registers the components this entity relies on, exactly once per process.
    @MainActor private static let registerRealityKitTypes: Void = {
        GLTFComponent.registerComponent()
        GLTFNodeComponent.registerComponent()
        GLTFMaterialSlotsComponent.registerComponent()
        GLTFMergedMeshComponent.registerComponent()
        GLTFDeformedMeshComponent.registerComponent()
        GLTFMaterialPassComponent.registerComponent()
        GLTFSkinIndexComponent.registerComponent()
        GLTFAnimationPlaybackComponent.registerComponent()
        GLTFAnimationSystem.registerSystem()
    }()

    init(document: GLTFDocument, sceneIndex: Int, outputColorSpace: GLTFOutputColorSpace) {
        super.init()
        _ = Self.registerRealityKitTypes
        components.set(GLTFComponent(document: document, sceneIndex: sceneIndex, outputColorSpace: outputColorSpace))
    }

    /// Also builds the `clone(recursive:)` copies, which inherit the ``GLTFComponent``
    /// but not the runtime bindings.
    public required init() {
        super.init()
        _ = Self.registerRealityKitTypes
    }

    /// The pose the document describes before any animation runs, solved once.
    func restPose() throws -> GLTFRestPose {
        if let cachedRestPose { return cachedRestPose }
        let pose = try GLTFRestPose(nodes: gltf.nodes)
        cachedRestPose = pose
        return pose
    }

    /// The builder has validated the node hierarchy by now.
    func setNodeEntities(_ nodes: [Entity?]) {
        nodeEntities = nodes
        // The locals are read as the node entities were given them, so the pose and the
        // entities agree to the bit from the start.
        let pose = GLTFPose(children: gltf.nodes.map { $0.children ?? [] },
                            locals: gltf.nodes.map { GLTFNodeTransform($0.localTransform) })
        pose.didWriteLocalTransform = { [unowned self] index, transform in
            MainActor.assumeIsolated { copyToNodeEntity(transform, ofNode: index) }
        }
        self.pose = pose
    }

    /// The pose is solved by ``flushDeformation()`` once the entity graph is complete.
    func registerSkinBinding(modelEntity: ModelEntity,
                             skeleton: MeshResource.Skeleton,
                             jointEntities: [Entity]) {
        skinBindings.append(SkinBinding(modelEntity: modelEntity,
                                        jointNodes: jointEntities.map { $0.components[GLTFNodeComponent.self]?.nodeIndex ?? -1 },
                                        parentIndices: skeleton.joints.map(\.parentIndex),
                                        deformedMesh: modelEntity.deformedMesh))
        needsSkinSolveSetUp = true
    }

    // MARK: - Node entities

    private func copyToNodeEntity(_ transform: GLTFNodeTransform, ofNode index: Int) {
        guard isSynchronized(index), let entity = entity(forNodeAt: index) else { return }
        entity.transform = Transform(transform)
    }

    private func isSynchronized(_ index: Int) -> Bool {
        guard case .nodes(let requested) = nodeEntitySynchronization else { return true }
        if synchronizedNodes == nil, let pose {
            // A node's world transform folds in every node above it, so those are kept too, and
            // so are the nodes the model's own meshes hang under, which draw where their entities say.
            var mask = [Bool](repeating: false, count: pose.nodeCount)
            let meshAnchors = ownModelEntities.compactMap { anchor(of: $0).node }
            for node in requested.union(meshAnchors) where mask.indices.contains(node) {
                var current: Int? = node
                while let index = current, !mask[index] {
                    mask[index] = true
                    current = pose.parent(ofNode: index)
                }
            }
            synchronizedNodes = mask
            pose.handedBackNodes = mask
        }
        return synchronizedNodes?[safe: index] ?? false
    }

    /// Copies the pose into every node entity ``nodeEntitySynchronization`` keeps, or into all
    /// of them, for when the kept set grows or a copy of the graph is taken.
    private func synchronizeNodeEntities(includingUnsynchronized: Bool = false) {
        guard let pose, let nodeEntities else { return }
        for (index, entity) in nodeEntities.enumerated() {
            guard let entity, includingUnsynchronized || isSynchronized(index) else { continue }
            let transform = Transform(pose.localTransform(ofNode: index))
            if entity.transform != transform {
                entity.transform = transform
            }
        }
    }

    /// Reads where this entity stands in the world into ``GLTFPose/rootMatrix``, which the
    /// pose's world-space reads fold in. The update does this before the runtimes run, so
    /// call it only to read world space after moving the entity within the same frame.
    public func refreshPoseRoot() {
        guard let pose else { return }
        pose.rootMatrix = transformMatrix(relativeTo: nil)
        pose.rootRotation = orientation(relativeTo: nil)
    }

    func registerMorphBindings(forNodeAt nodeIndex: Int, modelEntities: [ModelEntity], targetCount: Int) {
        let morphable = modelEntities.filter { $0.deformedMesh?.geometry.hasBlendShapes == true }
        guard !morphable.isEmpty else { return }
        morphBindings[nodeIndex, default: MorphBinding(modelEntities: [], targetCount: targetCount)]
            .modelEntities.append(contentsOf: morphable)
    }

    /// The animatable shader parameters are resolved once per material, so every entity
    /// sharing it shares them.
    func registerMaterialBinding(modelEntity: ModelEntity, slot: Int, materialIndex: Int, builder: GLTFSceneBuilder) {
        if materialStates[materialIndex] == nil {
            let drawing = builder.materialDrawing(forMaterialIndex: materialIndex)
            materialStates[materialIndex] = MaterialRuntimeState(
                animatable: builder.makeAnimatableMaterialState(forMaterialIndex: materialIndex),
                alphaMode: drawing.alphaMode,
                renderQueue: drawing.renderQueue
            )
        }
        materialStates[materialIndex]?.bindings.append(MaterialBinding(modelEntity: modelEntity, slot: slot))
    }

    /// A copy of the model as it stands, which keeps that pose, skin and material values while
    /// this entity moves on, and is ready to render once returned.
    ///
    /// A plain `clone(recursive:)` shares this entity's material values and meshes, so it is
    /// lit, colored and posed as this entity is, and the material setters do nothing on it.
    /// A snapshot holds its own, and its material setters change it alone. Like any clone it
    /// has no runtime: for a second model that animates, load it again, from the same loader
    /// to share the textures and meshes.
    public func snapshot() -> Self {
        // The copy carries the meshes as they are skinned now, and its node entities the
        // pose, so what hangs under them is copied where the pose puts it.
        updateSkinPose()
        synchronizeNodeEntities(includingUnsynchronized: true)
        let copy = clone(recursive: true)
        copy.freezeDeformedMeshes()
        // A glTF entity attached under this one, such as an accessory, is a document of its own,
        // whose material indices mean nothing in this entity's states; each takes its
        // parameters from its own original. A clone keeps the children in order, so the
        // two hierarchies pair up entity by entity.
        for (original, cloned) in zip(gltfEntitiesInHierarchy, copy.gltfEntitiesInHierarchy) {
            cloned.adoptMaterialParameters(of: original)
            // Its rows are written on the GPU, which a render taken straight away must not outrun.
            cloned.waitForMaterialStateWrites()
        }
        return copy
    }

    /// Gives every model entity under this clone a still copy of the mesh it shares with
    /// its original, so the original's next pose does not reach it.
    private func freezeDeformedMeshes() {
        for modelEntity in modelEntitiesInHierarchy {
            guard let shared = modelEntity.deformedMesh, !shared.isFrozen else { continue }
            do {
                modelEntity.setDeformedMesh(try shared.makeFrozenCopy())
            } catch {
                // The clone keeps drawing the shared mesh, which at least draws.
                GLTFResourceCache.gltfLogger.error("Failed to copy a mesh for a clone: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Gives this clone rows of its own copied from `original`'s, bound to the model
    /// entities of this entity's own document, never those of a glTF entity nested under it.
    private func adoptMaterialParameters(of original: GLTFEntity) {
        for modelEntity in ownModelEntities {
            guard let indices = modelEntity.components[GLTFMaterialSlotsComponent.self]?.materialIndices else {
                continue
            }
            for case let (slot, materialIndex?) in indices.enumerated() {
                if materialStates[materialIndex] == nil {
                    let originalState = original.materialStates[materialIndex]
                    let detached = originalState?.animatable?.detached()
                    materialStates[materialIndex] = MaterialRuntimeState(animatable: detached,
                                                                         needsFlush: detached != nil,
                                                                         alphaMode: originalState?.alphaMode ?? .OPAQUE,
                                                                         renderQueue: originalState?.renderQueue)
                }
                materialStates[materialIndex]?.bindings.append(MaterialBinding(modelEntity: modelEntity, slot: slot))
            }
        }
        flushDirtyMaterialStates()
    }

    /// This entity and every glTF entity nested under it, in a fixed traversal order.
    private var gltfEntitiesInHierarchy: [GLTFEntity] {
        descendants(of: GLTFEntity.self)
    }

    /// The model entities of this entity's own document: its hierarchy minus the subtrees
    /// of glTF entities nested under it.
    private var ownModelEntities: [ModelEntity] {
        descendants(of: ModelEntity.self) { $0 is GLTFEntity }
    }

    /// The glTF material indices any model entity under `root` renders with, additional
    /// render passes included, for scoping the runtime material APIs to part of a model.
    /// A model entity draws a whole glTF mesh, so the finest scope is the mesh.
    public func materialIndices(under root: Entity) -> Set<Int> {
        var indices: Set<Int> = []
        for modelEntity in root.modelEntitiesInHierarchy {
            guard let slots = modelEntity.components[GLTFMaterialSlotsComponent.self] else { continue }
            for case let index? in slots.materialIndices where !indices.contains(index) {
                guard let bindings = materialStates[index]?.bindings,
                      bindings.contains(where: { $0.modelEntity === modelEntity }) else { continue }
                indices.insert(index)
            }
        }
        return indices
    }

    /// Shows or hides the material slots drawing the additional render pass called `name`,
    /// such as MToon's outline: all of them, or those of `materials`, which
    /// ``materialIndices(under:)`` can scope. A hidden pass keeps its place in the skinning and morph
    /// solvers. Without `materials` it reads the entity graph, so a `clone(recursive:)` copy
    /// works too.
    public func setPassEnabled(_ isEnabled: Bool, named name: String, forMaterials materials: Set<Int>? = nil) {
        guard let materials else {
            forEachPass(named: name) { $0.setMergedVisibility(isEnabled) }
            return
        }
        for materialIndex in materials {
            forEachPassSlot(named: name, ofMaterial: materialIndex) { passEntity, slot in
                passEntity.setMergedSlotVisibility(isEnabled, slots: [slot])
            }
        }
    }

    /// Puts the slots of the pass called `name` back to the visibility its shader built it
    /// with, undoing ``setPassEnabled(_:named:forMaterials:)``.
    public func resetPassEnabled(named name: String, forMaterials materials: Set<Int>? = nil) {
        guard let materials else {
            forEachPass(named: name) { $0.resetMergedVisibility() }
            return
        }
        for materialIndex in materials {
            forEachPassSlot(named: name, ofMaterial: materialIndex) { passEntity, slot in
                passEntity.setMergedSlotVisibility(passEntity.initialMergedSlotVisibility(at: slot), slots: [slot])
            }
        }
    }

    // MARK: - Materials drawn by the caller

    /// What a command buffer of the same device waits on to read the vertices every skinning and
    /// morphing submitted so far writes, such as after this frame's update (``GLTFDeformationFence/wait(in:)``).
    public static func deformationFence() throws -> GLTFDeformationFence {
        let context = try GLTFDeformationContext.shared()
        return GLTFDeformationFence(event: context.completion, value: context.submittedValue, device: context.device)
    }

    /// Where the material at `materialIndex` draws from, one entry per mesh and render pass drawing
    /// it, for a caller rendering it with Metal itself or giving its materials more to read.
    public func geometry(ofMaterial materialIndex: Int) -> [GLTFMaterialGeometry] {
        guard let state = materialStates[materialIndex] else { return [] }
        return state.bindings.compactMap { binding in
            let modelEntity = binding.modelEntity
            guard let mesh = modelEntity.deformedMesh,
                  let slot = mesh.drawnSlots[safe: binding.slot] else { return nil }
            return GLTFMaterialGeometry(modelEntity: modelEntity,
                                        passName: modelEntity.components[GLTFMaterialPassComponent.self]?.name,
                                        materialSlot: binding.slot,
                                        mesh: mesh.lowLevelMesh,
                                        alphaMode: state.alphaMode,
                                        renderQueue: state.renderQueue,
                                        slot: mesh.geometry.slots[slot])
        }
    }

    /// Stops RealityKit drawing `materials`, additional render passes included, while their
    /// vertices keep deforming every frame, for a caller that draws them from
    /// ``geometry(ofMaterial:)``. `false` draws them again. Whether a pass shows stays
    /// with ``setPassEnabled(_:named:forMaterials:)`` either way, and
    /// ``GLTFMaterialGeometry/isVisible`` tells the caller.
    public func setDrawnByCaller(_ isDrawnByCaller: Bool, forMaterials materials: Set<Int>) {
        for materialIndex in materials {
            for binding in materialStates[materialIndex]?.bindings ?? [] {
                binding.modelEntity.setMergedSlotsDrawnByCaller(isDrawnByCaller, slots: [binding.slot])
            }
        }
    }

    private func forEachPass(named name: String, _ body: (ModelEntity) -> Void) {
        for passEntity in modelEntitiesInHierarchy
        where passEntity.components[GLTFMaterialPassComponent.self]?.name == name {
            body(passEntity)
        }
    }

    /// Found through the material runtime rather than the entity graph, so a material's
    /// slots are found wherever their subtree is reparented.
    private func forEachPassSlot(named name: String, ofMaterial materialIndex: Int, _ body: (ModelEntity, Int) -> Void) {
        for binding in materialStates[materialIndex]?.bindings ?? []
        where binding.modelEntity.components[GLTFMaterialPassComponent.self]?.name == name {
            body(binding.modelEntity, binding.slot)
        }
    }

    // MARK: - Animatable material runtime state
    //
    // Shader parameters describe a material, not an entity, so they are stored once per
    // material index and pushed to every entity rendering with it.

    /// Sets one color of the material at `materialIndex` in `gltf.materials` wherever
    /// this entity draws it, as a VRM expression's material color bind does, and
    /// pushes it to the GPU at once. It lets a plain glTF be recolored at runtime, such as
    /// a prop whose light color the user picks.
    public func setMaterialColor(_ color: SIMD4<Float>,
                                 for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                                 ofMaterial materialIndex: Int) {
        applyMaterialColor(color, type: type, materialIndex: materialIndex)
        flushDirtyMaterialStates()
    }

    /// ``setMaterialColor(_:for:ofMaterial:)`` without the flush, for a caller writing
    /// several colors before flushing once.
    func applyMaterialColor(_ color: SIMD4<Float>,
                            type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                            materialIndex: Int) {
        let vrmColor = outputColorSpace.color(color)
        applyMaterialValue(ofMaterial: materialIndex,
                           toState: { $0.setColor(color, for: type) },
                           toMaterial: { $0.settingColor(vrmColor, for: type) })
    }

    /// Writes a value through the material's runtime state when `toState` reports the state
    /// claims it, marking it for flush, and onto the RealityKit materials drawing it otherwise.
    /// A shader owning the value applies it from its own parameters, so writing both would
    /// apply it twice.
    func applyMaterialValue(ofMaterial materialIndex: Int,
                            toState: (any VRMAnimatableMaterialState) -> Bool,
                            toMaterial: (any Material) -> any Material) {
        if let animatable = materialStates[materialIndex]?.animatable, toState(animatable) {
            materialStates[materialIndex]?.needsFlush = true
        } else {
            mapMaterials(ofMaterial: materialIndex, toMaterial)
        }
    }

    /// The runtime state of the material at `materialIndex`, if its shader made a `State`.
    public func materialState<State: VRMAnimatableMaterialState>(_ type: State.Type,
                                                                 ofMaterial materialIndex: Int) -> State? {
        materialStates[materialIndex]?.animatable as? State
    }

    /// Edits the runtime state of every material whose shader made a `State`, then pushes
    /// the changed ones to the GPU once per material. `mutate` returns whether it changed
    /// anything; `materials` narrows which materials are edited.
    ///
    /// Returns false when no material matched, or while a state that failed to flush stays dirty.
    @discardableResult
    public func updateMaterialStates<State: VRMAnimatableMaterialState>(
        _ type: State.Type,
        forMaterials materials: Set<Int>? = nil,
        _ mutate: (State) -> Bool
    ) -> Bool {
        var foundState = false
        for (index, materialState) in materialStates {
            if let materials, !materials.contains(index) { continue }
            guard let state = materialState.animatable as? State else { continue }
            foundState = true
            if mutate(state) {
                materialStates[index]?.needsFlush = true
            }
        }
        return flushDirtyMaterialStates() && foundState
    }

    /// Blocks until every material state's writes reach the GPU, for a one-off render
    /// on a `RealityRenderer`.
    public func waitForMaterialStateWrites() {
        for state in materialStates.values {
            state.animatable?.waitForWrites()
        }
    }

    /// Pushes each dirty material's pending parameter writes to the GPU once per material,
    /// and reports whether every one of them landed.
    @discardableResult
    func flushDirtyMaterialStates() -> Bool {
        MToonParameterTexture.batchWrites { flushDirtyMaterialStatesNow() }
    }

    private func flushDirtyMaterialStatesNow() -> Bool {
        var didFlushAll = true
        for (materialIndex, state) in materialStates where state.needsFlush {
            guard let animatable = state.animatable, animatable.prepareFlush() else {
                // The GPU still holds the previous values: stay dirty and retry next flush.
                didFlushAll = false
                continue
            }
            // A state pushing its values through a resource the materials already hold has
            // nothing to apply.
            if animatable.updatesMaterialsOnFlush {
                mapMaterials(ofMaterial: materialIndex) { animatable.apply(to: $0) }
            }
            materialStates[materialIndex]?.needsFlush = false
        }
        return didFlushAll
    }

    /// Rewrites the material everywhere it is drawn, touching only its own slots of
    /// each entity's materials array.
    func mapMaterials(ofMaterial materialIndex: Int,
                      _ transform: (any Material) -> any Material) {
        guard let bindings = materialStates[materialIndex]?.bindings else { return }
        for binding in bindings {
            guard var component = binding.modelEntity.components[ModelComponent.self],
                  component.materials.indices.contains(binding.slot) else { continue }
            component.materials[binding.slot] = transform(component.materials[binding.slot])
            binding.modelEntity.components.set(component)
        }
    }

    /// The way this entity faces. A plain glTF scene is taken to face +Z; a model that
    /// knows better overrides this.
    public var frontDirection: SIMD3<Float> { SIMD3(0, 0, 1) }

    /// Takes the transforms of node entities posed from outside the runtime into ``pose``,
    /// which the runtimes and skinning read from then on. Writing ``pose`` directly needs no
    /// call. Only the node entities ``nodeEntitySynchronization`` keeps are read: the others
    /// do not hold the pose.
    public func invalidateSkinPose() {
        adoptNodeEntityTransforms()
        hasAdoptedNodeEntities = true
        // A mesh entity moved within the model reads its root joints from a new place.
        needsSkinAnchorCheck = true
    }

    /// While every node entity is kept a copy of the pose, code may still pose one without
    /// saying so, as it could before the pose existed, so each update starts by reading
    /// them back. A narrower ``nodeEntitySynchronization`` asks the caller to write ``pose``.
    func adoptNodeEntitiesPosedFromOutside() {
        defer { hasAdoptedNodeEntities = false }
        guard nodeEntitySynchronization == .all, !hasAdoptedNodeEntities else { return }
        adoptNodeEntityTransforms()
    }

    private func adoptNodeEntityTransforms() {
        guard let pose, let nodeEntities else { return }
        for (index, entity) in nodeEntities.enumerated() {
            guard let entity, isSynchronized(index) else { continue }
            pose.adoptLocalTransform(GLTFNodeTransform(entity.transform), ofNode: index)
        }
    }

    /// ``invalidateSkinPose()`` narrowed to the entities that were posed. An entity that is
    /// no node, such as a mesh entity moved within the model, has its meshes re-anchored.
    public func invalidateSkinPose(for joints: some Sequence<Entity>) {
        guard let pose else { return }
        for joint in joints {
            guard let index = nodeIndex(of: joint) else {
                needsSkinAnchorCheck = true
                continue
            }
            pose.adoptLocalTransform(GLTFNodeTransform(joint.transform), ofNode: index)
        }
    }

    /// Solves the skinned meshes against the joints as they stand, where they have moved
    /// since the last solve, and submits their deformation.
    ///
    /// The update loop does this once a frame, so this is for a caller reading or copying
    /// the model between updates: a `clone(recursive: true)` taken while a joint has moved
    /// carries the mesh as the last solve left it, which is a pose the joints no longer
    /// describe. ``snapshot()`` does it for you.
    public func updateSkinPose() {
        flushDeformation()
    }

    private static let signposter = OSSignposter(subsystem: "com.github.tattn.VRMKit", category: "Deformation")

    /// Solves the skeletons whose joints moved, then submits the skinning and morphing
    /// of every mesh whose pose or weights moved since the last submit, in one command
    /// buffer. Nothing is submitted for a held pose.
    ///
    /// The entities drawing one glTF mesh, its render passes and render-queue groups,
    /// hold the same pose and weights, so the first of them deforms the vertices once
    /// into the vertex buffers of them all. Every dispatch shares one compute encoder:
    /// an encoder costs the GPU more than a dispatch does.
    func flushDeformation() {
        flushSkinPoseIfNeeded()
        guard let pending = deformedMeshes.first(where: \.isDeformationPending) else { return }
        let context = pending.source.context
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "VRMKit deformation"
        var deformations: [(mesh: GLTFDeformedMesh, outputs: [MTLBuffer])] = []
        var deformationBySource: [ObjectIdentifier: Int] = [:]
        // The interval is the CPU side of a submit, for a trace to set against the GPU's.
        let interval = Self.signposter.beginInterval("VRMKit deformation")
        defer { Self.signposter.endInterval("VRMKit deformation", interval) }
        for mesh in deformedMeshes {
            guard let output = mesh.beginDeformation(using: commandBuffer) else { continue }
            let source = ObjectIdentifier(mesh.source)
            if let index = deformationBySource[source],
               deformations[index].outputs.count < GLTFDeformedMesh.maxOutputCount {
                deformations[index].outputs.append(output)
            } else {
                deformationBySource[source] = deformations.count
                deformations.append((mesh, [output]))
            }
        }
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "VRMKit deformation"
            encoder.setComputePipelineState(context.pipeline)
            for (mesh, outputs) in deformations {
                mesh.encodeDeformation(into: outputs, with: encoder)
            }
            encoder.endEncoding()
        }
        context.commit(commandBuffer)
    }

    /// Re-solves the skin pose only where a node has moved since the last solve, so a
    /// model holding a pose rewrites no skeleton, and one moving its eyes alone rewrites
    /// only the rows of the eyes.
    func flushSkinPoseIfNeeded() {
        guard let pose else { return }
        if needsSkinAnchorCheck {
            needsSkinAnchorCheck = false
            needsSkinSolveSetUp = needsSkinSolveSetUp || skinSolves.contains { solve in
                let anchor = anchor(of: solve.anchorEntity)
                return anchor.node != solve.anchorNode || anchor.offset != solve.anchorOffset
            }
        }
        if needsSkinSolveSetUp {
            setUpSkinSolves(pose: pose)
            _ = pose.takeNodesMovedForSkinning()
            for index in skinSolves.indices {
                solveAllRows(of: index, pose: pose)
            }
            return
        }
        guard pose.hasNodesMovedForSkinning else { return }
        changedSkinSolves.removeAll(keepingCapacity: true)
        changedSkinSolves.append(contentsOf: repeatElement(false, count: skinSolves.count))
        for node in pose.takeNodesMovedForSkinning() where node < skinRowsByNode.count && !skinRowsByNode[node].isEmpty {
            let transform = Transform(pose.localTransform(ofNode: node))
            for (solve, row) in skinRowsByNode[node] where !skinSolves[solve].isDependent(row) {
                if skinSolves[solve].rows[row] != transform {
                    skinSolves[solve].rows[row] = transform
                    changedSkinSolves[solve] = true
                }
            }
        }
        // A root or seam row is read through nodes outside its joint, any of which may be the
        // one that moved, and a skeleton has only a few of them.
        for solve in skinSolves.indices {
            for row in skinSolves[solve].dependentRows {
                let transform = dependentRow(row, of: skinSolves[solve], pose: pose)
                if skinSolves[solve].rows[row] != transform {
                    skinSolves[solve].rows[row] = transform
                    changedSkinSolves[solve] = true
                }
            }
            if changedSkinSolves[solve] {
                setSkinPose(of: solve)
            }
        }
    }

    private func setUpSkinSolves(pose: GLTFPose) {
        needsSkinSolveSetUp = false
        var solves: [SkinSolve] = []
        for binding in skinBindings {
            guard let mesh = binding.deformedMesh else { continue }
            let (anchorNode, anchorOffset) = anchor(of: binding.modelEntity)
            if let existing = solves.firstIndex(where: {
                $0.jointNodes == binding.jointNodes && $0.anchorNode == anchorNode && $0.anchorOffset == anchorOffset
            }) {
                solves[existing].meshes.append(mesh)
                continue
            }
            solves.append(SkinSolve(jointNodes: binding.jointNodes,
                                    parentIndices: binding.parentIndices,
                                    anchorNode: anchorNode,
                                    anchorOffset: anchorOffset,
                                    anchorEntity: binding.modelEntity,
                                    meshes: [mesh]))
        }
        var rowsByNode = [[(solve: Int, row: Int)]](repeating: [], count: pose.nodeCount)
        for (solveIndex, solve) in solves.enumerated() {
            for (row, node) in solve.jointNodes.enumerated() where rowsByNode.indices.contains(node) {
                rowsByNode[node].append((solveIndex, row))
            }
        }
        // The rows already written are kept, so a mesh is rewritten only when its pose changes.
        for index in solves.indices {
            if let previous = skinSolves.first(where: { $0.meshes.first === solves[index].meshes.first }),
               previous.jointNodes == solves[index].jointNodes {
                solves[index].rows = previous.rows
            }
        }
        skinSolves = solves
        skinRowsByNode = rowsByNode
    }

    /// The node a model entity hangs under, nil for the model's root, and where it stands
    /// below that node.
    private func anchor(of modelEntity: Entity) -> (node: Int?, offset: simd_float4x4) {
        var current = modelEntity.parent
        while let entity = current, entity !== self {
            if let index = nodeIndex(of: entity) {
                return (index, modelEntity.transformMatrix(relativeTo: entity))
            }
            current = entity.parent
        }
        return (nil, modelEntity.transformMatrix(relativeTo: self))
    }

    private func solveAllRows(of index: Int, pose: GLTFPose) {
        var solve = skinSolves[index]
        var rows: [Transform] = []
        var dependentRows: [Int] = []
        rows.reserveCapacity(solve.jointNodes.count)
        for row in solve.jointNodes.indices {
            if readsThroughModel(row, of: solve, pose: pose) {
                dependentRows.append(row)
                rows.append(dependentRow(row, of: solve, pose: pose))
            } else {
                rows.append(Transform(pose.localTransform(ofNode: solve.jointNodes[row])))
            }
        }
        solve.dependentRows = dependentRows
        let changed = solve.rows != rows
        solve.rows = rows
        skinSolves[index] = solve
        if changed {
            setSkinPose(of: index)
        }
    }

    /// A skeleton pose is each joint read in the space of the joint above it, which a
    /// joint's own transform already is whenever the skeleton and the node hierarchy agree
    /// about its parent. glTF skins are authored that way, so the common case is free.
    private func readsThroughModel(_ row: Int, of solve: SkinSolve, pose: GLTFPose) -> Bool {
        let node = solve.jointNodes[row]
        guard node >= 0, let parentRow = solve.parentIndices[safe: row] ?? nil,
              let parentNode = solve.jointNodes[safe: parentRow] else { return true }
        return pose.parent(ofNode: node) != parentNode
    }

    private func dependentRow(_ row: Int, of solve: SkinSolve, pose: GLTFPose) -> Transform {
        let node = solve.jointNodes[row]
        guard node >= 0 else { return Transform() }
        let base: simd_float4x4
        if let parentRow = solve.parentIndices[safe: row] ?? nil,
           let parentNode = solve.jointNodes[safe: parentRow], parentNode >= 0 {
            base = pose.modelMatrix(ofNode: parentNode)
        } else {
            base = (solve.anchorNode.map { pose.modelMatrix(ofNode: $0) } ?? matrix_identity_float4x4) * solve.anchorOffset
        }
        return Transform(matrix: base.inverse * pose.modelMatrix(ofNode: node))
    }

    private func setSkinPose(of index: Int) {
        for mesh in skinSolves[index].meshes {
            mesh.setJointTransforms(skinSolves[index].rows)
        }
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension Transform {
    init(_ transform: GLTFNodeTransform) {
        self.init(scale: transform.scale, rotation: transform.rotation, translation: transform.translation)
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFNodeTransform {
    init(_ transform: Transform) {
        self.init(translation: transform.translation, rotation: transform.rotation, scale: transform.scale)
    }
}

/// The point a command buffer waits for to read deformed vertices (``GLTFEntity/deformationFence()``).
public struct GLTFDeformationFence: @unchecked Sendable {
    public let event: any MTLSharedEvent
    public let value: UInt64
    /// The device the vertices live on, which a command buffer waiting on the fence has to share.
    public let device: any MTLDevice

    /// Has `commandBuffer`, of ``device``, wait for the fence before it runs.
    public func wait(in commandBuffer: any MTLCommandBuffer) {
        commandBuffer.encodeWaitForEvent(event, value: value)
    }
}

/// Which node entities of a ``GLTFEntity`` stay a copy of its ``GLTFEntity/pose``.
public enum GLTFNodeEntitySynchronization: Equatable, Sendable {
    /// Every node entity.
    case all
    /// These nodes, by index in the pose, such as the bones something is attached to, the
    /// nodes the model's own meshes hang under, and every node above them. The other node
    /// entities keep the transform they had.
    case nodes(Set<Int>)
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension Entity {
    /// Every `ModelEntity` in this entity's hierarchy, including itself.
    var modelEntitiesInHierarchy: [ModelEntity] {
        descendants(of: ModelEntity.self)
    }

    /// This entity and every one under it that is a `T`, depth first in a fixed order,
    /// skipping the subtrees below the root that `pruning` matches.
    func descendants<T: Entity>(of type: T.Type, pruning: (Entity) -> Bool = { _ in false }) -> [T] {
        var result: [T] = []
        var stack: [Entity] = [self]
        while let entity = stack.popLast() {
            if entity !== self, pruning(entity) { continue }
            if let match = entity as? T {
                result.append(match)
            }
            stack.append(contentsOf: entity.children)
        }
        return result
    }
}
#endif
