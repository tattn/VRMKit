#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit

/// Carries the loaded document on the entity, so `clone(recursive:)` copies still
/// answer ``GLTFEntity/document``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFComponent: Component {
    let document: GLTFDocument
    let sceneIndex: Int
}

/// The glTF node a loaded entity was built from, identified by array index:
/// `name` is optional and may repeat.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFNodeComponent: Component {
    public let nodeIndex: Int
}

/// Marks a model entity as an additional render pass of its glTF materials, such as
/// MToon's inverted-hull outline, rather than the materials themselves. What each
/// slot starts showing lives in the entity's ``GLTFMergedMeshCatalog``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFMaterialPassComponent: Component {
    public let name: String
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

    /// glTF node index → the entity built for it, for this scene.
    private var nodeEntities: [Entity?]?

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

    struct SkinBinding {
        let modelEntity: ModelEntity
        let skeleton: MeshResource.Skeleton
        let jointEntities: [Entity]
        /// Stands in for `skeleton.id`, so the per-frame solve dedups without hashing strings.
        let skeletonKey: Int
    }

    private(set) var skinBindings: [SkinBinding] = []
    private var skeletonKeys: [String: Int] = [:]
    /// Joint entity → every (skeleton, joint index) it poses, resolved once at
    /// registration for the fine-grained dirty path.
    private var jointSlots: [Entity.ID: [(skeletonKey: Int, jointIndex: Int)]] = [:]

    /// The last pose solved for one skeleton, kept across frames so a solve
    /// recomputes only the joints that moved.
    private struct SolvedSkeletonPose {
        /// The model world the pose was read against, which keeps a binding drawn
        /// elsewhere from reusing what another solved in the same pass.
        var modelWorld: simd_float4x4
        var transforms: [Transform]
        /// Rows read through the scene graph rather than off the joint's own
        /// transform: the skeleton's roots and seams. Nodes outside the skeleton
        /// move them, so every solve re-reads and compares these.
        var dependentRows: Set<Int>
    }

    private var solvedPoses: [Int: SolvedSkeletonPose] = [:]

    /// Whether any joint may have moved since the skin pose was last solved. Every
    /// runtime that poses a joint without saying which sets this rather than solving
    /// the skeleton itself.
    private var isSkinPoseDirty = false
    /// The joints known to have moved, per skeleton, for runtimes that do say.
    private var dirtyJoints: [Int: Set<Int>] = [:]
    /// Whether a moved node no skeleton owns asks the next solve to re-read the
    /// rows read through the scene graph, which such a node can sit on.
    private var needsDependentRowSolve = false

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

        @MainActor
        func hasPass(named name: String) -> Bool {
            bindings.contains { $0.modelEntity.components[GLTFMaterialPassComponent.self]?.name == name }
        }
    }

    var materialStates: [Int: MaterialRuntimeState] = [:]

    // Backing store for the MToon API (GLTFEntity+MToon.swift).
    var mtoonLightDirection = MToonMaterialParameters.defaultLightDirection
    var mtoonLightColor = SIMD3<Float>(1, 1, 1)
    var mtoonAmbientColor = SIMD3<Float>(0, 0, 0)

    // Backing store for the animation API (GLTFEntity+Animation.swift).
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
        GLTFMaterialPassComponent.registerComponent()
        GLTFSkinIndexComponent.registerComponent()
        GLTFAnimationPlaybackComponent.registerComponent()
        GLTFAnimationSystem.registerSystem()
    }()

    init(document: GLTFDocument, sceneIndex: Int) {
        super.init()
        _ = Self.registerRealityKitTypes
        components.set(GLTFComponent(document: document, sceneIndex: sceneIndex))
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

    func setNodeEntities(_ nodes: [Entity?]) {
        nodeEntities = nodes
    }

    /// The pose is solved by ``flushSkinPose()`` once the entity graph is complete.
    func registerSkinBinding(modelEntity: ModelEntity,
                             skeleton: MeshResource.Skeleton,
                             jointEntities: [Entity]) {
        let key: Int
        if let existing = skeletonKeys[skeleton.id] {
            key = existing
        } else {
            key = skeletonKeys.count
            skeletonKeys[skeleton.id] = key
            // Bindings sharing a skeleton share its joint entities, so the lookup is
            // built once per skeleton.
            for (jointIndex, joint) in jointEntities.enumerated() {
                jointSlots[joint.id, default: []].append((key, jointIndex))
            }
        }
        skinBindings.append(SkinBinding(modelEntity: modelEntity,
                                        skeleton: skeleton,
                                        jointEntities: jointEntities,
                                        skeletonKey: key))
    }

    func registerMorphBindings(forNodeAt nodeIndex: Int, modelEntities: [ModelEntity], targetCount: Int) {
        let morphable = modelEntities.filter { $0.components.has(BlendShapeWeightsComponent.self) }
        guard !morphable.isEmpty else { return }
        morphBindings[nodeIndex, default: MorphBinding(modelEntities: [], targetCount: targetCount)]
            .modelEntities.append(contentsOf: morphable)
    }

    /// The animatable shader parameters are resolved once per material, so every entity
    /// sharing it shares them.
    func registerMaterialBinding(modelEntity: ModelEntity, slot: Int, materialIndex: Int, builder: GLTFSceneBuilder) {
        if materialStates[materialIndex] == nil {
            materialStates[materialIndex] = MaterialRuntimeState(
                animatable: builder.makeAnimatableMaterialState(forMaterialIndex: materialIndex)
            )
        }
        materialStates[materialIndex]?.bindings.append(MaterialBinding(modelEntity: modelEntity, slot: slot))
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

    /// Shows or hides every material slot drawing the additional render pass called
    /// `name`, such as MToon's outline. A hidden pass keeps its place in the skinning
    /// and morph solvers. Read from the entity graph, so a `clone(recursive:)` copy
    /// works too.
    public func setPassEnabled(_ isEnabled: Bool, named name: String) {
        forEachPass(named: name) { $0.setMergedVisibility(isEnabled) }
    }

    /// Puts every slot drawing `name` back to the state its shader declared, undoing
    /// a ``setPassEnabled(_:named:)``.
    public func resetPassEnabled(named name: String) {
        forEachPass(named: name) { $0.resetMergedVisibility() }
    }

    /// One material slot of one pass entity: a pass entity draws several
    /// materials, so this is the unit pass visibility moves in.
    private struct PassSlotKey: Hashable {
        let entity: Entity.ID
        let slot: Int
    }

    /// Pass visibility a runtime override replaced, keyed by pass name, material and slot.
    /// Recording it per material lets overrides on different material sets compose.
    private var passVisibilityBeforeOverride: [String: [Int: [PassSlotKey: Bool]]] = [:]

    /// Shows or hides the `name` passes of `materials` for as long as an override lasts,
    /// remembering the visibility they replace. Only the first call to cover a material
    /// records it.
    func overridePassEnabled(_ isEnabled: Bool, named name: String, forMaterials materials: Set<Int>) {
        for materialIndex in materials {
            let needsRecord = passVisibilityBeforeOverride[name]?[materialIndex] == nil
            var replaced: [PassSlotKey: Bool] = [:]
            forEachPassSlot(named: name, ofMaterial: materialIndex) { passEntity, slot in
                if needsRecord, let isVisible = passEntity.mergedMesh?.visibleSlots[safe: slot] {
                    replaced[PassSlotKey(entity: passEntity.id, slot: slot)] = isVisible
                }
                passEntity.setMergedSlotVisibility(isEnabled, slots: [slot])
            }
            if needsRecord, !replaced.isEmpty {
                passVisibilityBeforeOverride[name, default: [:]][materialIndex] = replaced
            }
        }
    }

    /// Puts the `name` passes of `materials` back to the visibility
    /// ``overridePassEnabled(_:named:forMaterials:)`` replaced.
    func releasePassEnabledOverride(named name: String, forMaterials materials: Set<Int>) {
        for materialIndex in materials {
            guard let replaced = passVisibilityBeforeOverride[name]?.removeValue(forKey: materialIndex) else {
                continue
            }
            forEachPassSlot(named: name, ofMaterial: materialIndex) { passEntity, slot in
                let isVisible = replaced[PassSlotKey(entity: passEntity.id, slot: slot)]
                    ?? passEntity.initialMergedSlotVisibility(at: slot)
                passEntity.setMergedSlotVisibility(isVisible, slots: [slot])
            }
        }
        if passVisibilityBeforeOverride[name]?.isEmpty == true {
            passVisibilityBeforeOverride[name] = nil
        }
    }

    private func forEachPass(named name: String, _ body: (ModelEntity) -> Void) {
        for passEntity in modelEntitiesInHierarchy
        where passEntity.components[GLTFMaterialPassComponent.self]?.name == name {
            body(passEntity)
        }
    }

    /// Found through the material runtime rather than the entity graph, so an override
    /// follows its materials wherever their subtree is reparented.
    private func forEachPassSlot(named name: String, ofMaterial materialIndex: Int, _ body: (ModelEntity, Int) -> Void) {
        for binding in materialStates[materialIndex]?.bindings ?? []
        where binding.modelEntity.components[GLTFMaterialPassComponent.self]?.name == name {
            body(binding.modelEntity, binding.slot)
        }
    }

    // MARK: - Animatable material runtime state
    //
    // Shader parameters describe a material, not an entity, so they are stored once per
    // material index and pushed to every entity rendering with it. visionOS has no
    // `CustomMaterial`, so these all no-op there.

    /// Edits a material's animatable shader state, marking it for flush. Returns false
    /// when the material has no such state or does not animate what `mutate` writes,
    /// which is the cue to fall back to the RealityKit material properties.
    func mutateAnimatableState(ofMaterial materialIndex: Int,
                               _ mutate: (any VRMAnimatableMaterialState) -> Bool) -> Bool {
        guard let animatable = materialStates[materialIndex]?.animatable,
              mutate(animatable) else { return false }
        materialStates[materialIndex]?.needsFlush = true
        return true
    }

    /// Pushes each dirty material's pending parameter writes to the GPU once per material,
    /// and reports whether every one of them landed.
    @discardableResult
    func flushDirtyMaterialStates() -> Bool {
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

    /// Whether this entity already refreshes its skin pose once per frame on its own,
    /// in which case the animation tick must not solve the same skeleton.
    var refreshesSkinningPerFrame: Bool { false }

    /// The way this entity faces. A plain glTF scene is taken to face +Z; a model that
    /// knows better overrides this.
    public var frontDirection: SIMD3<Float> { SIMD3(0, 0, 1) }

    /// Tells the runtime a joint entity was posed from outside it, so the skinned meshes
    /// catch up on the next update. Animation, constraints and spring bones already do this.
    public func invalidateSkinPose() {
        isSkinPoseDirty = true
    }

    /// ``invalidateSkinPose()`` narrowed to the joints that actually moved: only their
    /// rows, and the rows read through the scene graph, are re-solved on the next
    /// update. A node no skeleton owns still schedules that pass, since a skeleton's
    /// root or seam row may be read through it.
    public func invalidateSkinPose(for joints: some Sequence<Entity>) {
        guard !isSkinPoseDirty else { return }
        for joint in joints {
            guard let slots = jointSlots[joint.id] else {
                needsDependentRowSolve = true
                continue
            }
            for slot in slots {
                dirtyJoints[slot.skeletonKey, default: []].insert(slot.jointIndex)
            }
        }
    }

    /// Re-solves the skin pose of every skin binding from the current joint transforms.
    func flushSkinPose() {
        isSkinPoseDirty = true
        solveSkinPose()
    }

    /// Re-solves the skin pose only where a joint has moved since the last solve, so a
    /// model holding a pose stops rewriting every skeleton each frame, and one moving
    /// its eyes alone rewrites only the skeletons the eyes belong to.
    func flushSkinPoseIfNeeded() {
        guard isSkinPoseDirty || needsDependentRowSolve || !dirtyJoints.isEmpty else { return }
        solveSkinPose()
    }

    private func solveSkinPose() {
        let solvesAllJoints = isSkinPoseDirty
        isSkinPoseDirty = false
        needsDependentRowSolve = false
        let dirty = dirtyJoints
        dirtyJoints.removeAll(keepingCapacity: true)
        guard !skinBindings.isEmpty else { return }

        // What each skeleton resolved to in this pass, shared by the bindings drawing
        // it, such as a mesh and its outline twin.
        var changedPoses: [Int: JointTransforms] = [:]
        var unchangedKeys: Set<Int> = []
        for binding in skinBindings {
            let key = binding.skeletonKey
            // A skeleton with no moved joint and no row read through the scene graph
            // cannot have changed, and is skipped before its world is even read.
            if !solvesAllJoints, dirty[key] == nil,
               let cached = solvedPoses[key], cached.dependentRows.isEmpty {
                continue
            }
            let modelWorld = binding.modelEntity.transformMatrix(relativeTo: nil)
            if let cached = solvedPoses[key] {
                if cached.modelWorld == modelWorld {
                    if let pose = changedPoses[key] {
                        setSkinPose(pose, for: binding)
                        continue
                    }
                    if unchangedKeys.contains(key) { continue }
                }
                // A moved model world is no reason to solve fully: only the rows read
                // through the scene graph are read against it, which a partial solve re-reads.
                if !solvesAllJoints {
                    solvePartially(cached, dirtyRows: dirty[key], for: binding, modelWorld: modelWorld,
                                   changedPoses: &changedPoses, unchangedKeys: &unchangedKeys)
                    continue
                }
            }
            let solved = jointTransforms(for: binding)
            let pose = JointTransforms(solved.transforms)
            solvedPoses[key] = SolvedSkeletonPose(modelWorld: modelWorld,
                                                  transforms: solved.transforms,
                                                  dependentRows: solved.dependentRows)
            changedPoses[key] = pose
            unchangedKeys.remove(key)
            setSkinPose(pose, for: binding)
        }
    }

    /// Recomputes only the moved rows and the scene-graph-read rows of one solved
    /// skeleton. Joints are posed in their skeleton parent's space, so a moved joint
    /// rewrites its own row alone: its subtree hangs off it in the skeleton. A pose
    /// no row of which changed is not written back to any binding.
    private func solvePartially(_ cached: SolvedSkeletonPose,
                                dirtyRows: Set<Int>?,
                                for binding: SkinBinding,
                                modelWorld: simd_float4x4,
                                changedPoses: inout [Int: JointTransforms],
                                unchangedKeys: inout Set<Int>) {
        var updated = cached
        updated.modelWorld = modelWorld
        var changed = false
        for row in dirtyRows ?? [] where row < updated.transforms.count && !updated.dependentRows.contains(row) {
            let (transform, isDependent) = jointTransform(at: row, of: binding)
            if isDependent {
                // A joint reparented since the last full solve reads through the
                // scene graph from now on.
                updated.dependentRows.insert(row)
            }
            if transform != updated.transforms[row] {
                updated.transforms[row] = transform
                changed = true
            }
        }
        for row in updated.dependentRows where row < updated.transforms.count {
            let transform = jointTransform(at: row, of: binding).transform
            if transform != updated.transforms[row] {
                updated.transforms[row] = transform
                changed = true
            }
        }
        solvedPoses[binding.skeletonKey] = updated
        guard changed else {
            unchangedKeys.insert(binding.skeletonKey)
            return
        }
        let pose = JointTransforms(updated.transforms)
        changedPoses[binding.skeletonKey] = pose
        setSkinPose(pose, for: binding)
    }

    private func setSkinPose(_ transforms: JointTransforms, for binding: SkinBinding) {
        let existing = binding.modelEntity.components[SkeletalPosesComponent.self]
        var pose = existing?.poses[binding.skeleton.id]
            ?? existing?.poses.default
            ?? SkeletalPose(id: binding.skeleton.id, from: binding.skeleton)
        pose.jointTransforms = transforms

        var component = existing ?? SkeletalPosesComponent(poses: [pose])
        component.poses[pose.id] = pose
        component.poses.default = pose
        binding.modelEntity.components.set(component)
    }

    /// A skeleton pose is each joint read in the space of the joint above it, which a
    /// joint's own transform already is whenever the skeleton and the scene graph agree
    /// about its parent. glTF skins are authored that way, so the common case is free.
    private func jointTransforms(for binding: SkinBinding) -> (transforms: [Transform], dependentRows: Set<Int>) {
        var transforms: [Transform] = []
        var dependentRows: Set<Int> = []
        transforms.reserveCapacity(binding.jointEntities.count)
        for index in 0..<binding.jointEntities.count {
            let (transform, isDependent) = jointTransform(at: index, of: binding)
            transforms.append(transform)
            if isDependent {
                dependentRows.insert(index)
            }
        }
        return (transforms, dependentRows)
    }

    /// One row of a skeleton pose, and whether it was read through the scene graph:
    /// such a row can move without its joint being touched.
    private func jointTransform(at index: Int, of binding: SkinBinding) -> (transform: Transform, isDependent: Bool) {
        let jointEntities = binding.jointEntities
        let joints = binding.skeleton.joints
        let joint = jointEntities[index]
        // A joint the skeleton gives no parent is read in the model's space.
        let base: Entity
        if index < joints.count, let parentIndex = joints[index].parentIndex, parentIndex < jointEntities.count {
            base = jointEntities[parentIndex]
        } else {
            base = binding.modelEntity
        }
        if joint.parent === base {
            return (joint.transform, false)
        }
        return (Transform(matrix: joint.transformMatrix(relativeTo: base)), true)
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension ModelEntity {
    /// Writes `weights` onto the blend-shape targets positionally, as glTF defines for
    /// `mesh.weights`, `node.weights` and `weights` channels alike.
    func applyMorphWeights(_ weights: [Float]) {
        let current = blendWeights
        guard !current.isEmpty else { return }
        // Compared before any copy: a held pose is the common case, and writing the sets
        // would re-upload the weights.
        func differs(_ set: [Float]) -> Bool {
            weights.enumerated().contains { targetIndex, weight in
                targetIndex < set.count && set[targetIndex] != weight
            }
        }
        guard current.contains(where: differs) else { return }

        var sets = current
        for setIndex in sets.indices {
            for (targetIndex, weight) in weights.enumerated() where targetIndex < sets[setIndex].count {
                sets[setIndex][targetIndex] = weight
            }
        }
        blendWeights = sets
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension Entity {
    /// Every `ModelEntity` in this entity's hierarchy, including itself.
    var modelEntitiesInHierarchy: [ModelEntity] {
        var result: [ModelEntity] = []
        var stack: [Entity] = [self]
        while let entity = stack.popLast() {
            if let modelEntity = entity as? ModelEntity {
                result.append(modelEntity)
            }
            stack.append(contentsOf: entity.children)
        }
        return result
    }
}
#endif
