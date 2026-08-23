#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit

/// Carries the loaded document on the entity, so the copies `clone(recursive:)`
/// makes still answer ``GLTFEntity/document``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFComponent: Component {
    let document: GLTFDocument
    let sceneIndex: Int
}

/// The glTF node a loaded entity was built from. The array index is a node's
/// canonical identity, since `name` is optional and may repeat.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFNodeComponent: Component {
    public let nodeIndex: Int
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFMaterialIndexComponent: Component {
    let materialIndex: Int
}

/// Marks a model entity as one additional render pass of its glTF material,
/// such as MToon's inverted-hull outline, rather than the material itself.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFMaterialPassComponent: Component {
    public let name: String
    /// What ``GLTFEntity/resetPassEnabled(named:)`` puts back.
    let isInitiallyEnabled: Bool
}

/// The glTF skin a model entity is skinned by. It survives `clone(recursive:)`,
/// so a mesh built once and cloned per node still binds its own joints.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFSkinIndexComponent: Component {
    let skinIndex: Int
}

/// The root entity of a loaded glTF scene.
///
/// Besides the entity graph it keeps what the animation runtime binds against —
/// the document, the node index → `Entity` mapping and the skin / morph
/// bindings — and the render state of each glTF material, which the MToon and
/// VRM expression runtimes drive.
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
    private var nodeEntities: [Entity?] = []

    /// Whether this entity carries the bindings the animation runtime drives.
    ///
    /// `clone(recursive:)` copies the entity graph and the document, but the
    /// bindings point at the entities of the original, so a copy is not
    /// animatable. Load the scene again to get one that is.
    public private(set) var hasRuntimeBindings = false

    /// The entity built for the glTF node at `index`, or nil when the index is out
    /// of range or the node is not part of this scene.
    public func entity(forNodeAt index: Int) -> Entity? {
        guard nodeEntities.indices.contains(index) else { return nil }
        return nodeEntities[index]
    }

    struct SkinBinding {
        let modelEntity: ModelEntity
        let skeleton: MeshResource.Skeleton
        let jointEntities: [Entity]
    }

    private(set) var skinBindings: [SkinBinding] = []

    /// Whether a joint has moved since the skin pose was last solved. The loader
    /// solves it once the graph is complete, and every runtime that poses a
    /// joint sets this rather than solving the skeleton itself.
    private var isSkinPoseDirty = false

    struct MorphBinding {
        var modelEntities: [ModelEntity]
        let targetCount: Int
    }

    /// glTF node index → the blend shapes a `weights` channel writes to.
    private(set) var morphBindings: [Int: MorphBinding] = [:]

    /// Everything the runtime tracks per glTF material. Keying this by material
    /// index, rather than copying it onto every entity, is what keeps the
    /// animatable shader parameters single-source.
    struct MaterialRuntimeState {
        /// Every entity rendering the material, its additional passes included,
        /// so a parameter flush reaches all of them.
        var modelEntities: [ModelEntity] = []
        /// Present when what renders the material makes one, as MToon does.
        var animatable: (any VRMAnimatableMaterialState)?
        var needsFlush = false

        @MainActor
        func hasPass(named name: String) -> Bool {
            modelEntities.contains { $0.components[GLTFMaterialPassComponent.self]?.name == name }
        }
    }

    var materialStates: [Int: MaterialRuntimeState] = [:]

    // Backing store for the MToon API (GLTFEntity+MToon.swift).
    var mtoonLightDirection = MToonMaterialParameters.defaultLightDirection
    var mtoonLightColor = SIMD3<Float>(1, 1, 1)
    var mtoonAmbientColor = SIMD3<Float>(0, 0, 0)

    // Backing store for the animation API (GLTFEntity+Animation.swift).
    var animationMetadata: [GLTFAnimation]?
    /// One decoder for the whole document, because samplers of different
    /// animations routinely share an input accessor.
    lazy var animationDecoder = GLTFAnimationDecoder(document: document)
    private var cachedRestPose: GLTFRestPose?
    var animationRuntimes: [Int: GLTFAnimationRuntime] = [:]
    var activeAnimationControllers: [GLTFAnimationPlaybackController] = []

    /// Registers the components this entity relies on, exactly once per process.
    @MainActor private static let registerRealityKitTypes: Void = {
        GLTFComponent.registerComponent()
        GLTFNodeComponent.registerComponent()
        GLTFMaterialIndexComponent.registerComponent()
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

    /// Also builds the copies `clone(recursive:)` returns, which inherit the
    /// ``GLTFComponent`` but not the runtime bindings.
    public required init() {
        super.init()
        _ = Self.registerRealityKitTypes
    }

    /// The pose the document describes before any animation runs, solved once.
    func restPose() throws -> GLTFRestPose {
        if let cachedRestPose { return cachedRestPose }
        let pose = try GLTFRestPose(nodes: gltf.nodes ?? [])
        cachedRestPose = pose
        return pose
    }

    func setNodeEntities(_ nodes: [Entity?]) {
        nodeEntities = nodes
        hasRuntimeBindings = true
    }

    /// The pose is solved by ``updateSkinning()``, which the loader calls once
    /// the entity graph the joints live in is complete.
    func registerSkinBinding(modelEntity: ModelEntity,
                             skeleton: MeshResource.Skeleton,
                             jointEntities: [Entity]) {
        skinBindings.append(SkinBinding(modelEntity: modelEntity,
                                        skeleton: skeleton,
                                        jointEntities: jointEntities))
    }

    func registerMorphBindings(forNodeAt nodeIndex: Int, modelEntities: [ModelEntity], targetCount: Int) {
        let morphable = modelEntities.filter { $0.components.has(BlendShapeWeightsComponent.self) }
        guard !morphable.isEmpty else { return }
        morphBindings[nodeIndex, default: MorphBinding(modelEntities: [], targetCount: targetCount)]
            .modelEntities.append(contentsOf: morphable)
    }

    /// The animatable shader parameters are resolved once per material, so every
    /// entity sharing it shares them.
    func registerMaterialBinding(modelEntity: ModelEntity, materialIndex: Int, loader: GLTFEntityLoader) {
        if materialStates[materialIndex] == nil {
            materialStates[materialIndex] = MaterialRuntimeState(
                animatable: loader.makeAnimatableMaterialState(forMaterialIndex: materialIndex)
            )
        }
        materialStates[materialIndex]?.modelEntities.append(modelEntity)
    }

    /// The glTF material indices any model entity under `root` renders with,
    /// additional render passes included, for scoping the runtime material
    /// APIs to part of a model.
    ///
    /// Only this entity's own runtime is counted: an entity loaded from
    /// another document and parented under `root`, an attached accessory say,
    /// is skipped, since its indices point into that document's materials. A
    /// `clone(recursive:)` copy carries no material runtime, so under one the
    /// answer is empty.
    public func materialIndices(under root: Entity) -> Set<Int> {
        var indices: Set<Int> = []
        for modelEntity in root.modelEntitiesInHierarchy {
            guard let index = modelEntity.components[GLTFMaterialIndexComponent.self]?.materialIndex,
                  !indices.contains(index),
                  let boundEntities = materialStates[index]?.modelEntities,
                  boundEntities.contains(where: { $0 === modelEntity }) else { continue }
            indices.insert(index)
        }
        return indices
    }

    /// Shows or hides every entity drawing the additional render pass called
    /// `name`, such as MToon's outline. A hidden pass draws nothing, though it
    /// keeps its place in the skinning and morph solvers.
    ///
    /// A pass a shader declared with `isInitiallyEnabled: false` is shown for
    /// the first time this way. Read from the entity graph rather than the
    /// material runtime state, so it works on a `clone(recursive:)` copy too.
    public func setPassEnabled(_ isEnabled: Bool, named name: String) {
        forEachPass(named: name) { $0.isEnabled = isEnabled }
    }

    /// Puts every entity drawing `name` back to the state its shader declared,
    /// undoing a ``setPassEnabled(_:named:)`` that showed or hid them all.
    public func resetPassEnabled(named name: String) {
        forEachPass(named: name) { $0.isEnabled = isInitiallyEnabled($0) }
    }

    /// Pass visibility a runtime override replaced, keyed by pass name, by the
    /// glTF material overridden, and by the entity drawing it. Recording it per
    /// material is what lets overrides scoped to different material sets
    /// compose: each releases only the visibility it replaced.
    private var passVisibilityBeforeOverride: [String: [Int: [Entity.ID: Bool]]] = [:]

    /// Shows or hides the `name` passes of `materials` for as long as an
    /// override lasts, remembering the visibility they replace. Only the first
    /// call to cover a material records it, so an override adjusting itself
    /// still releases back to where it started.
    func overridePassEnabled(_ isEnabled: Bool, named name: String, forMaterials materials: Set<Int>) {
        for materialIndex in materials {
            let needsRecord = passVisibilityBeforeOverride[name]?[materialIndex] == nil
            var replaced: [Entity.ID: Bool] = [:]
            forEachPass(named: name, ofMaterial: materialIndex) { passEntity in
                if needsRecord { replaced[passEntity.id] = passEntity.isEnabled }
                passEntity.isEnabled = isEnabled
            }
            if needsRecord, !replaced.isEmpty {
                passVisibilityBeforeOverride[name, default: [:]][materialIndex] = replaced
            }
        }
    }

    /// Puts the `name` passes of `materials` back to the visibility
    /// ``overridePassEnabled(_:named:forMaterials:)`` replaced. A material
    /// without an override in force has nothing to undo.
    func releasePassEnabledOverride(named name: String, forMaterials materials: Set<Int>) {
        for materialIndex in materials {
            guard let replaced = passVisibilityBeforeOverride[name]?.removeValue(forKey: materialIndex) else {
                continue
            }
            forEachPass(named: name, ofMaterial: materialIndex) {
                $0.isEnabled = replaced[$0.id] ?? isInitiallyEnabled($0)
            }
        }
        if passVisibilityBeforeOverride[name]?.isEmpty == true {
            passVisibilityBeforeOverride[name] = nil
        }
    }

    private func isInitiallyEnabled(_ passEntity: ModelEntity) -> Bool {
        passEntity.components[GLTFMaterialPassComponent.self]?.isInitiallyEnabled ?? true
    }

    private func forEachPass(named name: String, _ body: (ModelEntity) -> Void) {
        for passEntity in modelEntitiesInHierarchy
        where passEntity.components[GLTFMaterialPassComponent.self]?.name == name {
            body(passEntity)
        }
    }

    /// The entities drawing the `name` pass of one material, found through the
    /// material runtime rather than the entity graph, so an override follows
    /// its materials wherever their subtree is reparented to.
    private func forEachPass(named name: String, ofMaterial materialIndex: Int, _ body: (ModelEntity) -> Void) {
        for passEntity in materialStates[materialIndex]?.modelEntities ?? []
        where passEntity.components[GLTFMaterialPassComponent.self]?.name == name {
            body(passEntity)
        }
    }

    // MARK: - Animatable material runtime state
    //
    // Shader parameters describe a *material*, not an entity, so they are stored
    // once per material index and pushed to every entity that renders with it.
    // visionOS has no `CustomMaterial`, so no material has them and these all
    // no-op there without platform conditionals of their own.

    /// Edits a material's animatable shader state, marking it for flush. Returns
    /// false when no such state renders the material, or when it does not animate
    /// the value `mutate` writes: the caller's cue to fall back to the RealityKit
    /// material properties.
    func mutateAnimatableState(ofMaterial materialIndex: Int,
                               _ mutate: (any VRMAnimatableMaterialState) -> Bool) -> Bool {
        guard let animatable = materialStates[materialIndex]?.animatable,
              mutate(animatable) else { return false }
        materialStates[materialIndex]?.needsFlush = true
        return true
    }

    /// Pushes each dirty material's pending parameter writes to the GPU once per
    /// material, instead of once per binding that touched it, and answers
    /// whether every one of them landed.
    @discardableResult
    func flushDirtyMaterialStates() -> Bool {
        var didFlushAll = true
        for (materialIndex, state) in materialStates where state.needsFlush {
            guard let animatable = state.animatable, animatable.prepareFlush() else {
                // The GPU still holds the previous values, so the material stays
                // dirty and the next flush retries.
                didFlushAll = false
                continue
            }
            mapMaterials(ofMaterial: materialIndex) { animatable.apply(to: $0) }
            materialStates[materialIndex]?.needsFlush = false
        }
        return didFlushAll
    }

    func mapMaterials(ofMaterial materialIndex: Int,
                      _ transform: (any Material) -> any Material) {
        guard let modelEntities = materialStates[materialIndex]?.modelEntities else { return }
        for modelEntity in modelEntities {
            guard var component = modelEntity.components[ModelComponent.self] else { continue }
            component.materials = component.materials.map(transform)
            modelEntity.components.set(component)
        }
    }

    /// Whether this entity already refreshes its skin pose once per frame on its
    /// own, in which case the animation tick must not solve the same skeleton.
    var refreshesSkinningPerFrame: Bool { false }

    /// Tells the runtime that a joint entity was posed from outside it, so that
    /// the skinned meshes catch up on the next update.
    ///
    /// Animation playback, node constraints and spring bones do this for what
    /// they move; only code that poses a joint entity itself — a humanoid bone
    /// driven by head tracking, say — has to call it.
    public func invalidateSkinPose() {
        isSkinPoseDirty = true
    }

    /// Re-solves the skin pose from the current joint transforms.
    func flushSkinPose() {
        guard !skinBindings.isEmpty else {
            isSkinPoseDirty = false
            return
        }
        updateSkinning()
    }

    /// Re-solves the skin pose only when a joint has moved since the last solve,
    /// so a model holding a pose stops rewriting every skeleton each frame.
    func flushSkinPoseIfNeeded() {
        guard isSkinPoseDirty else { return }
        flushSkinPose()
    }

    /// Re-applies the skeletal pose of every skin binding from the current joint
    /// entity transforms.
    func updateSkinning() {
        isSkinPoseDirty = false
        // Bindings sharing a skeleton and model world transform, such as a mesh
        // and its outline twin, resolve to identical joint transforms.
        var solved: [String: (modelWorld: simd_float4x4, transforms: JointTransforms)] = [:]
        for binding in skinBindings {
            let modelWorld = binding.modelEntity.transformMatrix(relativeTo: nil)
            let transforms: JointTransforms
            if let cached = solved[binding.skeleton.id], cached.modelWorld == modelWorld {
                transforms = cached.transforms
            } else {
                transforms = jointTransforms(for: binding, modelWorld: modelWorld)
                solved[binding.skeleton.id] = (modelWorld, transforms)
            }
            setSkinPose(transforms, for: binding)
        }
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

    private func jointTransforms(for binding: SkinBinding,
                                 modelWorld: simd_float4x4) -> JointTransforms {
        let jointEntities = binding.jointEntities
        let joints = binding.skeleton.joints
        var transforms: [Transform] = []
        transforms.reserveCapacity(jointEntities.count)

        let modelWorldInverse = simd_inverse(modelWorld)
        // Each joint's world matrix is also its children's parent matrix.
        let jointWorlds = jointEntities.map { $0.transformMatrix(relativeTo: nil) }

        for index in 0..<jointEntities.count {
            let jointWorld = jointWorlds[index]
            let localMatrix: simd_float4x4
            if index < joints.count, let parentIndex = joints[index].parentIndex, parentIndex < jointEntities.count {
                localMatrix = simd_mul(simd_inverse(jointWorlds[parentIndex]), jointWorld)
            } else {
                localMatrix = simd_mul(modelWorldInverse, jointWorld)
            }
            transforms.append(Transform(matrix: localMatrix))
        }

        return JointTransforms(transforms)
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension ModelEntity {
    /// Writes `weights` onto the blend-shape targets positionally, as glTF defines
    /// for `mesh.weights`, `node.weights` and `weights` channels alike.
    func applyMorphWeights(_ weights: [Float]) {
        let current = blendWeights
        guard !current.isEmpty else { return }
        // Compared before any copy: a held pose, from a STEP segment or a
        // paused animation, is the common case, and writing the sets would copy
        // them and re-upload the weights for nothing.
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
