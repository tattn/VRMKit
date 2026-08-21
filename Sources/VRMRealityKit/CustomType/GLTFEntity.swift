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

/// The glTF material a model entity renders with.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFMaterialIndexComponent: Component {
    let materialIndex: Int
}

/// The glTF skin a model entity is skinned by. It survives `clone(recursive:)`,
/// so a mesh built once and cloned per node still binds its own joints.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFSkinIndexComponent: Component {
    let skinIndex: Int
}

/// The root entity of a loaded glTF scene.
///
/// Besides the entity graph it keeps what the animation runtime binds against:
/// the document, the node index → `Entity` mapping and the skin / morph bindings.
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

    /// One skinned model and the joint entities that drive it.
    struct SkinBinding {
        let modelEntity: ModelEntity
        let skeleton: MeshResource.Skeleton
        let jointEntities: [Entity]
    }

    private(set) var skinBindings: [SkinBinding] = []

    /// The blend shapes one node's morph weights write to, and the number of
    /// targets every weights array driving them has to carry.
    struct MorphBinding {
        var modelEntities: [ModelEntity]
        let targetCount: Int
    }

    /// glTF node index → the blend shapes a `weights` channel writes to.
    private(set) var morphBindings: [Int: MorphBinding] = [:]

    // Backing store for the animation API (GLTFEntity+Animation.swift).
    var animationMetadata: [GLTFAnimation]?
    /// One decoder for the whole document, because samplers of different
    /// animations routinely share an input accessor.
    lazy var animationDecoder = GLTFAnimationDecoder(document: document)
    var animationRuntimes: [Int: GLTFAnimationRuntime] = [:]
    var activeAnimationControllers: [GLTFAnimationPlaybackController] = []

    /// Registers the components this entity relies on, exactly once per process.
    @MainActor private static let registerRealityKitTypes: Void = {
        GLTFComponent.registerComponent()
        GLTFNodeComponent.registerComponent()
        GLTFMaterialIndexComponent.registerComponent()
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

    func setNodeEntities(_ nodes: [Entity?]) {
        nodeEntities = nodes
        hasRuntimeBindings = true
    }

    /// Records a skinned model. The pose is solved by ``updateSkinning()``, which
    /// the loader calls once the entity graph the joints live in is complete.
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

    /// Registers an entity as a renderer of `materialIndex`. ``VRMEntity`` overrides
    /// this to feed its MToon and expression machinery.
    func registerMaterialBinding(modelEntity: ModelEntity, materialIndex: Int, loader: GLTFEntityLoader) {}

    /// Whether this entity already refreshes its skin pose once per frame on its
    /// own, in which case the animation tick must not solve the same skeleton.
    var refreshesSkinningPerFrame: Bool { false }

    /// Re-applies the skeletal pose of every skin binding from the current joint
    /// entity transforms.
    func updateSkinning() {
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
