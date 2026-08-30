#if canImport(RealityKit)
import CoreGraphics
import Foundation
import OSLog
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

/// Carries the loaded VRM on the entity, so `clone(recursive:)` copies still answer
/// ``VRMEntity/vrm``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct VRMComponent: Component {
    let vrm: VRM
}

/// The root entity of a loaded VRM model, and the runtime that animates it.
///
/// A plain `Entity`, so adding it to a scene is all its lifetime needs: the parent
/// owns it, and ``VRMUpdateSystem`` animates it while it stays in the scene.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public final class VRMEntity: GLTFEntity {
    private static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "Expression")

    /// The VRM this entity was loaded from.
    ///
    /// - Precondition: the entity came from a ``VRMEntityLoader``, not from
    ///   ``init()``.
    public var vrm: VRM {
        guard let vrm = components[VRMComponent.self]?.vrm else {
            preconditionFailure("This VRMEntity carries no VRM. Load it with VRMEntityLoader.")
        }
        return vrm
    }

    public let humanoid = Humanoid()

    /// The expression accumulation and dirty tracking VRM defines; this entity
    /// only writes the results out.
    private let expressions = ExpressionRuntime<Entity>()
    var expressionClips: [ExpressionKey: ExpressionClip] { expressions.clips }
    private var firstPersonAnnotations: [FirstPersonAnnotation] = []
    private var springBones = SpringBoneRig<Entity>()
    private var nodeConstraints = NodeConstraintRig<Entity>()
    private var lookAt = LookAtRig<Entity>()
    // Blend-shape target -> weight-set positions, resolved on first write.
    private var blendShapeSlotCache: [MorphBindingKey: BlendShapeSlots] = [:]

    private lazy var expressionApplier = ExpressionApplier<Entity>(
        setMorphWeight: { [unowned self] weight, targetIndex, mesh in
            applyBlendShapeWeight(weight, targetIndex: targetIndex, on: mesh)
        },
        setMaterialColor: { [unowned self] color, type, materialIndex in
            applyMaterialColor(color, type: type, materialIndex: materialIndex)
        },
        setTextureTransform: { [unowned self] scale, offset, rotation, materialIndex in
            applyTextureTransform(scale: scale, offset: offset, rotation: rotation, materialIndex: materialIndex)
        },
        didApply: { [unowned self] in
            flushDirtyMaterialStates()
        }
    )

    /// Registers the components and system this entity relies on, exactly once per process.
    /// RealityKit instantiates a registered system for every scene, existing ones included,
    /// so registering on first use is enough.
    @MainActor private static let registerRealityKitTypes: Void = {
        VRMComponent.registerComponent()
        VRMUpdateComponent.registerComponent()
        VRMUpdateSystem.registerSystem()
    }()

    init(vrm: VRM, document: GLTFDocument, sceneIndex: Int) {
        super.init(document: document, sceneIndex: sceneIndex)
        _ = Self.registerRealityKitTypes
        components.set(VRMComponent(vrm: vrm))
        components.set(VRMUpdateComponent())
    }

    /// Also builds the `clone(recursive:)` copies, which inherit the ``VRMComponent``
    /// but not the runtime bindings, so they only render.
    public required init() {
        super.init()
        _ = Self.registerRealityKitTypes
    }

    /// Whether ``VRMUpdateSystem`` calls ``update(deltaTime:)`` on every render frame.
    /// Enabled by default; disable it to drive the timing yourself.
    public var isAutomaticUpdateEnabled: Bool {
        get { components.has(VRMUpdateComponent.self) }
        set {
            if newValue {
                components.set(VRMUpdateComponent())
            } else {
                components.remove(VRMUpdateComponent.self)
            }
        }
    }

    /// ``update(deltaTime:)`` ends by flushing the skin pose, so the animation tick
    /// must not solve it too.
    override var refreshesSkinningPerFrame: Bool { isAutomaticUpdateEnabled }

    /// How the spring bones swing: the wind pushing them, if any.
    public var springBoneConfiguration: SpringBoneConfiguration {
        get { springBones.configuration }
        set { springBones.configuration = newValue }
    }

    /// Forgets the motion the spring bones carry between frames, so the next update
    /// starts them at rest. Call it after teleporting the model.
    public func resetSpringBones() {
        springBones.reset()
    }

    /// The versions disagree about which way a model faces, and loading converts no
    /// coordinates, so the entity faces whichever way its VRM does.
    public override var frontDirection: SIMD3<Float> { vrm.forwardDirection }

    func setUpHumanoid(nodes: [Entity?]) {
        humanoid.setUp(boneNodes: vrm.boneNodes, nodes: nodes)
    }

    /// Called once per entity, right after its node hierarchy is built.
    func setUpBlendShapes(nodes: [Entity?],
                          meshes: [Int: [GLTFSceneBuilder.SceneMesh]],
                          builder: GLTFSceneBuilder) {
        expressions.setUp(
            plan: VRMExpressionPlan(vrm: vrm),
            morphBindings: { bind in
                switch bind.target {
                case .mesh(let index):
                    return (meshes[index] ?? []).map {
                        BlendShapeBinding(mesh: $0.entity, index: bind.index, weight: bind.weight)
                    }
                case .node(let index):
                    guard let node = nodes[safe: index] ?? nil else { return [] }
                    return [BlendShapeBinding(mesh: node, index: bind.index, weight: bind.weight)]
                }
            },
            materialColorBinding: { expression, bind in
                // A malformed bind only invalidates itself, never the whole load.
                guard let baseValue = try? currentMaterialColor(withMaterialIndex: bind.material,
                                                                type: bind.type,
                                                                builder: builder) else {
                    Self.logger.warning("""
                    Skipping invalid MaterialColorBind. \
                    expression=\(expression, privacy: .public) materialIndex=\(bind.material)
                    """)
                    return nil
                }
                return ExpressionMaterialColorBinding(material: bind.material,
                                                      type: bind.type,
                                                      targetValue: bind.targetValue,
                                                      baseValue: baseValue)
            },
            textureTransformBinding: { expression, bind in
                // As above, a malformed bind only invalidates itself.
                guard let base = try? currentTextureTransform(withMaterialIndex: bind.material,
                                                              builder: builder) else {
                    Self.logger.warning("""
                    Skipping invalid TextureTransformBind. \
                    expression=\(expression, privacy: .public) materialIndex=\(bind.material)
                    """)
                    return nil
                }
                return ExpressionTextureTransformBinding(material: bind.material,
                                                         baseScale: base.scale,
                                                         baseOffset: base.offset,
                                                         baseRotation: base.rotation,
                                                         targetScale: bind.scale,
                                                         targetOffset: bind.offset)
            }
        )
    }

    /// What each camera draws of each mesh. The `auto` cut is made as the meshes are built,
    /// so this only pairs it with the entity drawing it.
    func setUpFirstPerson(plan: VRMFirstPersonPlan,
                          nodes: [Entity?],
                          meshes: [Int: [GLTFSceneBuilder.SceneMesh]]) {
        let head = plan.headNode.flatMap { nodes[safe: $0] ?? nil }
        firstPersonAnnotations = meshes.sorted { $0.key < $1.key }.flatMap { meshIndex, sceneMeshes in
            sceneMeshes.map { sceneMesh in
                FirstPersonAnnotation(entity: sceneMesh.entity,
                                      type: plan.annotation(ofNodeAt: sceneMesh.nodeIndex, meshIndex: meshIndex),
                                      // An unskinned mesh cannot be cut, so the head takes it whole.
                                      hidesAutoInFirstPerson: sceneMesh.entity.isSameOrDescendant(of: head))
            }
        }
        setFirstPersonRenderMode(.thirdPerson)
    }

    func setUpNodeConstraints(gltfNodes: [GLTF.Node],
                              hierarchy: GLTFNodeHierarchy,
                              builder: GLTFSceneBuilder) throws {
        nodeConstraints = try NodeConstraintRig.make(vrm: vrm, gltfNodes: gltfNodes, hierarchy: hierarchy) {
            try builder.node(withNodeIndex: $0)
        }
    }

    func setUpSpringBones(builder: GLTFSceneBuilder) throws {
        springBones = try SpringBoneRig.make(vrm: vrm) { try builder.node(withNodeIndex: $0) }
    }

    func setUpLookAt(builder: GLTFSceneBuilder) throws {
        lookAt = try LookAtRig.make(vrm: vrm) { try builder.node(withNodeIndex: $0) }
    }

    /// What the eyes follow, nil to leave them at rest.
    ///
    /// A world-space position is kept on as either it or the model moves, so a model
    /// looking at the camera only has to be told where the camera is. A model stating no
    /// look-at keeps its eyes still whatever this is set to.
    public var lookAtTarget: LookAtTarget? {
        get { lookAt.target }
        set {
            lookAt.target = newValue
            applyLookAt()
        }
    }

    private func applyLookAt() {
        switch lookAt.apply() {
        case .unchanged:
            break
        case .posedBones:
            invalidateSkinPose(for: lookAt.posedNodes)
        case .weights(let weights):
            guard expressions.storeWeights(weights) else { return }
            expressions.apply(with: expressionApplier)
        }
    }

    /// The color a `materialColorBind` starts from. A state animating that color keeps
    /// it; everything else reads it from the RealityKit material.
    func currentMaterialColor(withMaterialIndex index: Int,
                              type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                              builder: GLTFSceneBuilder) throws -> SIMD4<Float> {
        if let color = materialStates[index]?.animatable?.color(for: type) {
            return color
        }
        return try builder.material(withMaterialIndex: index).currentColor(for: type)
    }

    /// The UV transform a `textureTransformBind` starts from. A state animating it keeps
    /// it; everything else reads it from the RealityKit material.
    func currentTextureTransform(withMaterialIndex index: Int,
                                 builder: GLTFSceneBuilder) throws -> MaterialParameterTypes.TextureCoordinateTransform {
        if let transform = materialStates[index]?.animatable?.textureTransform {
            return transform
        }
        return try builder.material(withMaterialIndex: index).currentTextureTransform
    }

    /// Advances node constraints, the gaze, spring bones and skinning by one frame.
    ///
    /// ``VRMUpdateSystem`` calls this once per render frame, so set
    /// ``isAutomaticUpdateEnabled`` to `false` before driving the timing manually. The skin
    /// pose is re-solved only when a joint has moved, so posing a humanoid bone directly has
    /// to be followed by ``GLTFEntity/invalidateSkinPose()``.
    public func update(deltaTime: TimeInterval) {
        let deltaTime = max(0, deltaTime)
        // Skinning runs last so this frame's constraint and spring-bone poses reach the
        // skinned meshes in the same frame they are solved. Each runtime hands over the
        // joints it moved, so only their skeletons are re-solved.
        if nodeConstraints.apply() {
            invalidateSkinPose(for: nodeConstraints.posedNodes)
        }
        // After the constraints, which may have posed the head the gaze is measured from,
        // and before the springs, which nothing about the eyes feeds into.
        applyLookAt()
        if springBones.update(deltaTime: deltaTime) {
            invalidateSkinPose(for: springBones.posedNodes)
        }
        flushSkinPoseIfNeeded()
    }

    public func setExpression(value: CGFloat, for key: ExpressionKey) {
        setExpressions([key: value])
    }

    /// Sets several expression weights and re-applies the result once. Applying
    /// re-accumulates every active clip, so prefer this over repeated
    /// ``setExpression(value:for:)`` calls in one frame.
    public func setExpressions(_ weights: [ExpressionKey: CGFloat]) {
        guard expressions.storeWeights(weights) else { return }
        expressions.apply(with: expressionApplier)
    }

    public func expression(for key: ExpressionKey) -> CGFloat {
        CGFloat(expressions.weight(for: key))
    }

    /// The expressions the model offers, each paired with the name it states them
    /// under.
    ///
    /// A VRM 0.x model's blend shape groups come in its own order; a VRM 1.0
    /// model's presets come first, then its custom expressions by name.
    public var availableExpressions: [ExpressionInfo] {
        expressions.availableExpressions
    }

    public func setFirstPersonRenderMode(_ mode: FirstPersonRenderMode) {
        for annotation in firstPersonAnnotations {
            // An `auto` mesh is cut rather than hidden, so the body below it stays.
            if annotation.type == .auto, applyFirstPersonCut(mode, to: annotation.entity) { continue }
            annotation.entity.isEnabled = !annotation.type.isHidden(in: mode,
                                                                    hidesAutoInFirstPerson: annotation.hidesAutoInFirstPerson)
        }
    }

    /// Draws `entity` with the triangles `mode` asks for, and says whether it was cut.
    /// The cut is baked per part, so a mesh worn head to foot keeps its body while
    /// the head's parts and triangles go.
    private func applyFirstPersonCut(_ mode: FirstPersonRenderMode, to entity: Entity) -> Bool {
        var cut = false
        for modelEntity in entity.modelEntitiesInHierarchy {
            guard let merged = modelEntity.mergedMesh, merged.catalog.hasFirstPersonCut else { continue }
            cut = true
            modelEntity.setMergedFirstPerson(mode == .firstPerson)
        }
        return cut
    }

    private func applyMaterialColor(_ color: SIMD4<Float>,
                                    type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                                    materialIndex: Int) {
        // A shader animating this color owns it in its own parameters; an unclaimed one
        // falls back below.
        if mutateAnimatableState(ofMaterial: materialIndex, { $0.setColor(color, for: type) }) {
            return
        }
        let vrmColor = VRMColor(simd: color)
        mapMaterials(ofMaterial: materialIndex) { $0.settingColor(vrmColor, for: type) }
    }

    private func applyTextureTransform(scale: SIMD2<Float>,
                                       offset: SIMD2<Float>,
                                       rotation: Float,
                                       materialIndex: Int) {
        // A shader animating the UV transform applies it from its own parameters; writing
        // the material-level transform too would transform the primary UV twice.
        if mutateAnimatableState(ofMaterial: materialIndex, {
            $0.setTextureTransform(scale: scale, offset: offset, rotation: rotation)
        }) {
            return
        }
        mapMaterials(ofMaterial: materialIndex) {
            $0.settingTextureTransform(scale: scale, offset: offset, rotation: rotation)
        }
    }

    /// Where one blend-shape target lives in a model entity's weight sets.
    private struct BlendShapeSlot {
        let modelEntity: ModelEntity
        /// (weight set, index within it) pairs the target writes to.
        let positions: [(set: Int, index: Int)]
    }

    /// One resolved target, remembering the meshes it was resolved against: a mesh
    /// variant re-lays the weight sets, so a resolution outliving any of them is
    /// made again.
    private struct BlendShapeSlots {
        let slots: [BlendShapeSlot]
        let resolvedMeshes: [(modelEntity: ModelEntity, mesh: ObjectIdentifier?)]

        @MainActor var isCurrent: Bool {
            resolvedMeshes.allSatisfy { entry in
                entry.mesh == (entry.modelEntity.components[ModelComponent.self]?.mesh)
                    .map(ObjectIdentifier.init)
            }
        }
    }

    private func applyBlendShapeWeight(_ weight: Float, targetIndex: Int, on mesh: Entity) {
        for slot in blendShapeSlots(targetIndex: targetIndex, on: mesh) {
            var weights = slot.modelEntity.blendWeights
            for position in slot.positions where position.set < weights.count
                && position.index < weights[position.set].count {
                weights[position.set][position.index] = weight
            }
            slot.modelEntity.blendWeights = weights
        }
    }

    /// Resolves the target's weight-set positions once per mesh, rather than looking up
    /// a blend-shape name on every write.
    private func blendShapeSlots(targetIndex: Int, on mesh: Entity) -> [BlendShapeSlot] {
        let key = MorphBindingKey(mesh: mesh, targetIndex: targetIndex)
        if let cached = blendShapeSlotCache[key], cached.isCurrent {
            return cached.slots
        }

        let targetName = "blendShape_\(targetIndex)"
        var slots: [BlendShapeSlot] = []
        var resolvedMeshes: [(modelEntity: ModelEntity, mesh: ObjectIdentifier?)] = []
        for modelEntity in mesh.modelEntitiesInHierarchy {
            resolvedMeshes.append((modelEntity,
                                   (modelEntity.components[ModelComponent.self]?.mesh)
                                       .map(ObjectIdentifier.init)))
            ensureBlendShapeComponent(on: modelEntity)
            let weights = modelEntity.blendWeights
            guard !weights.isEmpty else { continue }
            let names = modelEntity.blendWeightNames
            var positions: [(set: Int, index: Int)] = []
            if !names.isEmpty {
                for setIndex in names.indices {
                    if let nameIndex = names[setIndex].firstIndex(of: targetName),
                       nameIndex < weights[setIndex].count {
                        positions.append((setIndex, nameIndex))
                    }
                }
            }
            if positions.isEmpty {
                // Meshes without blend-shape names address targets positionally.
                for setIndex in weights.indices where targetIndex < weights[setIndex].count {
                    positions.append((setIndex, targetIndex))
                }
            }
            guard !positions.isEmpty else { continue }
            slots.append(BlendShapeSlot(modelEntity: modelEntity, positions: positions))
        }
        blendShapeSlotCache[key] = BlendShapeSlots(slots: slots, resolvedMeshes: resolvedMeshes)
        return slots
    }

    private func ensureBlendShapeComponent(on modelEntity: ModelEntity) {
        if modelEntity.components[BlendShapeWeightsComponent.self] != nil {
            return
        }
        guard let model = modelEntity.components[ModelComponent.self] else { return }
        let mapping = BlendShapeWeightsMapping(meshResource: model.mesh)
        modelEntity.components.set(BlendShapeWeightsComponent(weightsMapping: mapping))
    }
}


@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
/// Identifies one morph target on one mesh entity, both to accumulate expression
/// weights and to cache where the target lives in the blend-shape weight sets.
private struct MorphBindingKey: Hashable {
    let mesh: ObjectIdentifier
    let targetIndex: Int

    init(mesh: Entity, targetIndex: Int) {
        self.mesh = ObjectIdentifier(mesh)
        self.targetIndex = targetIndex
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
private struct FirstPersonAnnotation {
    let entity: Entity
    let type: FirstPersonAnnotationType
    let hidesAutoInFirstPerson: Bool
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
private extension Entity {
    func isSameOrDescendant(of ancestor: Entity?) -> Bool {
        guard let ancestor else { return false }
        var entity: Entity? = self
        while let current = entity {
            if current === ancestor {
                return true
            }
            entity = current.parent
        }
        return false
    }
}

/// Materials whose UV transform VRMKit can read and write uniformly.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
protocol TextureTransformableMaterial: Material {
    var textureCoordinateTransform: MaterialParameterTypes.TextureCoordinateTransform { get set }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension UnlitMaterial: TextureTransformableMaterial {}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension PhysicallyBasedMaterial: TextureTransformableMaterial {}

#if !os(visionOS)
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension CustomMaterial: TextureTransformableMaterial {}
#endif

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension Material {
    var currentTextureTransform: MaterialParameterTypes.TextureCoordinateTransform {
        (self as? any TextureTransformableMaterial)?.textureCoordinateTransform
            ?? MaterialParameterTypes.TextureCoordinateTransform()
    }

    func currentColor(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float> {
        switch self {
        case let material as UnlitMaterial:
            switch type {
            case .color:
                return material.color.tint.simd
            case .emissionColor, .shadeColor, .matcapColor, .rimColor, .outlineColor:
                return SIMD4<Float>(1, 1, 1, 1)
            }
        case let material as PhysicallyBasedMaterial:
            switch type {
            case .color:
                return material.baseColor.tint.simd
            case .emissionColor:
                return material.emissiveColor.color.simd
            // shadeColor / matcapColor / rimColor / outlineColor are MToon-only, so they
            // have no meaning on the PBR fallback material.
            case .shadeColor, .matcapColor, .rimColor, .outlineColor:
                return SIMD4<Float>(1, 1, 1, 1)
            }
        default:
            return SIMD4<Float>(1, 1, 1, 1)
        }
    }

    func settingTextureTransform(scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float = 0) -> Material {
        guard var material = self as? any TextureTransformableMaterial else { return self }
        material.textureCoordinateTransform = MaterialParameterTypes.TextureCoordinateTransform(offset: offset,
                                                                                               scale: scale,
                                                                                               rotation: rotation)
        return material
    }

    func settingColor(_ color: VRMColor,
                      for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> Material {
        switch self {
        case var material as UnlitMaterial:
            switch type {
            case .color:
                material.color.tint = color
            case .emissionColor, .shadeColor, .matcapColor, .rimColor, .outlineColor:
                break
            }
            return material
        case var material as PhysicallyBasedMaterial:
            switch type {
            case .color:
                material.baseColor.tint = color
            case .emissionColor:
                material.emissiveColor.color = color
            case .shadeColor, .matcapColor, .rimColor, .outlineColor:
                break
            }
            return material
        default:
            return self
        }
    }

}
#endif
