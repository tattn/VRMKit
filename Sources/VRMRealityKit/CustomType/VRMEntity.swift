#if canImport(RealityKit)
import CoreGraphics
import Foundation
import OSLog
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

/// Carries the loaded VRM on the entity, so the copies `clone(recursive:)` makes
/// through `init()` still answer ``VRMEntity/vrm``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct VRMComponent: Component {
    let vrm: VRM
}

/// The root entity of a loaded VRM model, and the runtime that animates it.
///
/// It is a plain `Entity`, so adding it to a scene is all its lifetime needs:
/// the parent entity owns it, and ``VRMUpdateSystem`` animates it for as long as
/// it stays in the scene.
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

    var expressionClips: [ExpressionKey: ExpressionClip] = [:]
    /// Input weights per expression, kept so that expressions sharing a morph
    /// target accumulate instead of overwriting one another.
    private var expressionWeights: [ExpressionKey: Float] = [:]
    private var materialColorClips: [ExpressionKey: [MaterialColorBinding]] = [:]
    private var textureTransformClips: [ExpressionKey: [TextureTransformBinding]] = [:]
    private var firstPersonAnnotations: [FirstPersonAnnotation] = []
    private var springBones: [VRMEntitySpringBone] = []
    private var nodeConstraints: [NodeConstraintBinding] = []
    // Binding indexes and their baseline values are fully determined by the
    // clips, so they are built once at load time instead of on every
    // expression change.
    private var morphBindingIndex: [MorphBindingKey: BlendShapeBinding] = [:]
    private var colorBindingIndex: [MaterialColorBindingKey: MaterialColorBinding] = [:]
    private var transformBindingIndex: [Int: TextureTransformBinding] = [:]
    // Values last pushed to the render state, so re-applying every clip on each
    // expression change only touches bindings whose value actually moved.
    private var appliedMorphWeights: [MorphBindingKey: Float] = [:]
    // Blend-shape target -> weight-set positions, resolved on first write.
    private var blendShapeSlotCache: [MorphBindingKey: [BlendShapeSlot]] = [:]
    private var appliedMaterialColors: [MaterialColorBindingKey: SIMD4<Float>] = [:]
    private var appliedTextureTransforms: [Int: SIMD4<Float>] = [:]

    /// Registers the components and the system this entity relies on. RealityKit
    /// instantiates registered systems for every scene, including scenes that
    /// already exist, so registering on first use is enough; `static let` runs
    /// the body exactly once.
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

    /// Required by `Entity`, which also builds the copies `clone(recursive:)`
    /// returns. Such a copy inherits the ``VRMComponent`` but not the runtime
    /// bindings, so it renders and ``update(deltaTime:)`` does nothing to it.
    public required init() {
        super.init()
        _ = Self.registerRealityKitTypes
    }

    /// Whether ``VRMUpdateSystem`` calls ``update(deltaTime:)`` automatically on
    /// every render frame. Enabled by default. Disable it to take over the
    /// per-frame timing and call ``update(deltaTime:)`` yourself.
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

    /// ``update(deltaTime:)`` ends by flushing the skin pose, so while the VRM
    /// runtime drives this entity the animation tick must not solve it too.
    override var refreshesSkinningPerFrame: Bool { isAutomaticUpdateEnabled }

    /// The versions disagree about which way a model faces, and loading
    /// converts no coordinates, so the entity faces whichever way its VRM does.
    public override var frontDirection: SIMD3<Float> { vrm.forwardDirection }

    func setUpHumanoid(nodes: [Entity?]) {
        humanoid.setUp(boneNodes: vrm.boneNodes, nodes: nodes)
    }

    /// Called once per entity, right after its node hierarchy is built. A VRM 0.x
    /// bind names a mesh index, so it drives every entity `meshes` has for it.
    func setUpBlendShapes(nodes: [Entity?], meshes: [Int: [Entity]], loader: VRMEntityLoader) throws {
        switch vrm {
        case .v0(let vrm0):
            // A 0.x group is loaded as the expression it stands for, so the
            // runtime below drives both versions through one set of clips.
            for group in vrm0.blendShapeMaster.blendShapeGroups {
                let morphBindings: [BlendShapeBinding] = group.binds?
                    .flatMap { bind in
                        (meshes[bind.mesh] ?? []).map {
                            BlendShapeBinding(mesh: $0, index: bind.index, weight: bind.weight)
                        }
                    } ?? []
                let clip = ExpressionClip(name: group.name,
                                          preset: group.expressionPreset,
                                          values: morphBindings,
                                          isBinary: group.isBinary,
                                          binaryRounding: .nearest)
                expressionClips[clip.key] = clip
            }
        case .v1(let vrm1):
            guard let expressions = vrm1.expressions else { return }
            for expressionClip in expressions.runtimeClips {
                let morphBindings: [BlendShapeBinding] = expressionClip.expression.morphTargetBinds?
                    .compactMap { bind in
                        guard nodes.indices.contains(bind.node),
                              let node = nodes[bind.node] else {
                            return nil
                        }
                        return BlendShapeBinding(mesh: node, index: bind.index, weight: bind.weight * 100.0)
                    } ?? []
                let runtimeClip = ExpressionClip(name: expressionClip.name,
                                                 preset: expressionClip.preset,
                                                 values: morphBindings,
                                                 isBinary: expressionClip.expression.isBinary ?? false,
                                                 overrideBlink: expressionClip.expression.overrideBlink ?? .none,
                                                 overrideLookAt: expressionClip.expression.overrideLookAt ?? .none,
                                                 overrideMouth: expressionClip.expression.overrideMouth ?? .none)
                expressionClips[runtimeClip.key] = runtimeClip

                let colorBindings: [MaterialColorBinding] = expressionClip.expression.materialColorBinds?
                    .compactMap { bind in
                        guard bind.targetValue.count >= 3 else { return nil }
                        // A malformed bind (e.g. out-of-range material index) only
                        // invalidates that bind, never the whole model load.
                        guard let baseValue = try? currentMaterialColor(withMaterialIndex: bind.material,
                                                                        type: bind.type,
                                                                        loader: loader) else {
                            Self.logger.warning("""
                            Skipping invalid MaterialColorBind. \
                            expression=\(expressionClip.name, privacy: .public) \
                            materialIndex=\(bind.material)
                            """)
                            return nil
                        }
                        return MaterialColorBinding(materialIndex: bind.material,
                                                    type: bind.type,
                                                    targetValue: SIMD4<Float>(bind.targetValue, default: 1.0),
                                                    baseValue: baseValue)
                    } ?? []
                if !colorBindings.isEmpty {
                    materialColorClips[runtimeClip.key] = colorBindings
                }

                let transformBindings: [TextureTransformBinding] = expressionClip.expression.textureTransformBinds?
                    .compactMap { bind in
                        guard let base = try? currentTextureTransform(withMaterialIndex: bind.material,
                                                                      loader: loader) else {
                            return nil
                        }
                        return TextureTransformBinding(materialIndex: bind.material,
                                                       baseScale: base.scale,
                                                       baseOffset: base.offset,
                                                       baseRotation: base.rotation,
                                                       targetScale: SIMD2<Float>(bind.scale, default: 1.0),
                                                       targetOffset: SIMD2<Float>(bind.offset, default: 0.0))
                    } ?? []
                if !transformBindings.isEmpty {
                    textureTransformClips[runtimeClip.key] = transformBindings
                }
            }
        }

        buildBindingIndexes()
    }

    /// Indexes every expression binding once, so applying weights only
    /// accumulates them instead of rediscovering the bindings each time.
    private func buildBindingIndexes() {
        let morphBindings = expressionClips.values.flatMap(\.values)
        for binding in morphBindings {
            let key = MorphBindingKey(mesh: binding.mesh, targetIndex: binding.index)
            morphBindingIndex[key] = binding
        }
        for bindings in materialColorClips.values {
            for binding in bindings {
                colorBindingIndex[binding.key] = binding
            }
        }
        for bindings in textureTransformClips.values {
            for binding in bindings {
                transformBindingIndex[binding.materialIndex] = binding
            }
        }
    }

    func setUpFirstPerson(nodes: [Entity?], meshes: [Int: [Entity]]) {
        switch vrm {
        case .v0(let vrm0):
            firstPersonAnnotations = vrm0.firstPerson.meshAnnotations.flatMap { annotation in
                guard let type = FirstPersonAnnotationType(vrm0Flag: annotation.firstPersonFlag) else {
                    return [FirstPersonAnnotation]()
                }
                return (meshes[annotation.mesh] ?? []).map {
                    FirstPersonAnnotation(entity: $0,
                                          type: type,
                                          hidesAutoInFirstPerson: false)
                }
            }
        case .v1(let vrm1):
            let head = humanoid.node(for: .head)
            firstPersonAnnotations = vrm1.firstPerson?.meshAnnotations.compactMap { annotation in
                guard nodes.indices.contains(annotation.node),
                      let node = nodes[annotation.node] else {
                    return nil
                }
                let type = FirstPersonAnnotationType(vrm1Type: annotation.type)
                return FirstPersonAnnotation(entity: node,
                                             type: type,
                                             hidesAutoInFirstPerson: type == .auto && node.isSameOrDescendant(of: head))
            } ?? []
        }
        setFirstPersonRenderMode(.thirdPerson)
    }

    func setUpNodeConstraints(gltfNodes: [GLTF.Node], loader: GLTFEntityLoader) throws {
        guard case .v1 = vrm else {
            nodeConstraints = []
            return
        }

        var bindings: [NodeConstraintBinding] = []
        for (targetIndex, gltfNode) in gltfNodes.enumerated() {
            guard let constraint = gltfNode.extensions?.nodeConstraint?.constraint,
                  let descriptor = VRMNodeConstraintDescriptor(constraint) else {
                continue
            }
            let sourceIndex = descriptor.source
            guard sourceIndex != targetIndex else {
                throw VRMError._dataInconsistent("VRMC_node_constraint source must not be destination: \(targetIndex)")
            }
            guard gltfNodes.indices.contains(sourceIndex) else {
                throw VRMError._dataInconsistent("VRMC_node_constraint source index is out of range: \(sourceIndex)")
            }

            let target = try loader.node(withNodeIndex: targetIndex)
            let source = try loader.node(withNodeIndex: sourceIndex)
            bindings.append(NodeConstraintBinding(targetIndex: targetIndex,
                                                  sourceIndex: sourceIndex,
                                                  descriptor: descriptor,
                                                  target: target,
                                                  source: source))
        }
        nodeConstraints = try orderNodeConstraints(
            bindings,
            targetIndex: { $0.targetIndex },
            sourceIndex: { $0.sourceIndex }
        )
    }

    func setUpSpringBones(loader: GLTFEntityLoader) throws {
        var springBones: [VRMEntitySpringBone] = []
        switch vrm {
        case .v0(let vrm0):
            let secondaryAnimation = vrm0.secondaryAnimation
            let allColliderGroups = try secondaryAnimation.colliderGroups.map {
                try VRMEntitySpringBoneColliderGroup(colliderGroup: $0, loader: loader)
            }
            for boneGroup in secondaryAnimation.boneGroups {
                guard !boneGroup.bones.isEmpty else { continue }
                let rootBones: [Entity] = try boneGroup.bones.compactMap { try loader.node(withNodeIndex: $0) }
                let centerNode = try? loader.node(withNodeIndex: boneGroup.center)
                let colliderGroups = boneGroup.colliderGroups.compactMap { allColliderGroups[safe: $0] }
                let springBone = VRMEntitySpringBone(center: centerNode,
                                                     rootBones: rootBones,
                                                     setting: SpringBoneJointSetting(vrm0BoneGroup: boneGroup),
                                                     colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        case .v1(let vrm1):
            guard let springBone = vrm1.springBone else { break }
            let allColliderGroups = try (springBone.colliderGroups ?? []).map {
                try VRMEntitySpringBoneColliderGroup(colliderGroup: $0, springBone: springBone, loader: loader)
            }
            for spring in springBone.springs ?? [] {
                let jointEntities = try spring.joints.map { try loader.node(withNodeIndex: $0.node) }
                // A chain of one joint is only a tail, so it swings nothing.
                guard jointEntities.count > 1 else { continue }
                let centerEntity = try spring.center.map { try loader.node(withNodeIndex: $0) }
                let colliderGroups = (spring.colliderGroups ?? []).compactMap { allColliderGroups[safe: $0] }
                let chain = zip(jointEntities, spring.joints).map { entity, joint in
                    (node: entity, setting: SpringBoneJointSetting(vrm1Joint: joint))
                }
                let springBone = VRMEntitySpringBone(center: centerEntity,
                                                     chain: chain,
                                                     colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        }
        self.springBones = springBones
    }

    /// The color a `materialColorBind` starts from. A state animating that color
    /// (MToon animates them all) keeps it; everything else reads it from the
    /// RealityKit material.
    func currentMaterialColor(withMaterialIndex index: Int,
                              type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                              loader: GLTFEntityLoader) throws -> SIMD4<Float> {
        if let color = materialStates[index]?.animatable?.color(for: type) {
            return color
        }
        return try loader.material(withMaterialIndex: index).currentColor(for: type)
    }

    /// The UV transform a `textureTransformBind` starts from. A state animating
    /// it (MToon does) keeps it; everything else reads it from the RealityKit
    /// material.
    func currentTextureTransform(withMaterialIndex index: Int,
                                 loader: GLTFEntityLoader) throws -> MaterialParameterTypes.TextureCoordinateTransform {
        if let transform = materialStates[index]?.animatable?.textureTransform {
            return transform
        }
        return try loader.material(withMaterialIndex: index).currentTextureTransform
    }

    /// Advances spring bones, node constraints, and skinning by one frame.
    ///
    /// ``VRMUpdateSystem`` calls this automatically once per render frame, so
    /// there is normally no need to call it. To drive the timing manually, set
    /// ``isAutomaticUpdateEnabled`` to `false` first, otherwise the model
    /// advances twice per frame.
    ///
    /// The skin pose is re-solved only when something has moved a joint since
    /// the last frame, so posing a humanoid bone directly has to be followed by
    /// ``GLTFEntity/invalidateSkinPose()``.
    public func update(deltaTime: TimeInterval) {
        let deltaTime = max(0, deltaTime)
        // Skinning runs last so that this frame's constraint and spring-bone
        // poses reach the skinned meshes in the same frame they are solved.
        var movedJoints = false
        for constraint in nodeConstraints where constraint.apply() {
            movedJoints = true
        }
        springBones.forEach { $0.update(deltaTime: deltaTime) }
        if !springBones.isEmpty || movedJoints {
            invalidateSkinPose()
        }
        flushSkinPoseIfNeeded()
    }

    public func setExpression(value: CGFloat, for key: ExpressionKey) {
        setExpressions([key: value])
    }

    /// Sets several expression weights and re-applies the result once.
    ///
    /// Prefer this over repeated ``setExpression(value:for:)`` calls when a single
    /// frame changes more than one expression (face tracking, lip sync): applying
    /// re-accumulates every active clip and can rebuild MToon parameter textures.
    public func setExpressions(_ weights: [ExpressionKey: CGFloat]) {
        var changed = false
        for (key, value) in weights where storeExpressionWeight(value, for: key) {
            changed = true
        }
        guard changed else { return }
        applyExpressions()
    }

    /// Records the input weight for `key`, returning whether it actually moved.
    private func storeExpressionWeight(_ value: CGFloat, for key: ExpressionKey) -> Bool {
        guard let key = canonicalExpressionKey(for: key),
              let clip = expressionClips[key] else { return false }
        return Self.store(clip.normalizedWeight(Double(value)), for: key, in: &expressionWeights)
    }

    /// Keeps `weights` free of the zero entries an accumulation would skip
    /// anyway, and reports whether the stored weight actually moved.
    private static func store<Key>(_ normalized: Double,
                                   for key: Key,
                                   in weights: inout [Key: Float]) -> Bool {
        let weight = normalized > 0 ? Float(normalized) : nil
        guard weight != weights[key] else { return false }
        if let weight {
            weights[key] = weight
        } else {
            weights.removeValue(forKey: key)
        }
        return true
    }

    public func expression(for key: ExpressionKey) -> CGFloat {
        guard let key = canonicalExpressionKey(for: key) else { return 0 }
        return CGFloat(expressionWeights[key] ?? 0)
    }

    public func setFirstPersonRenderMode(_ mode: FirstPersonRenderMode) {
        for annotation in firstPersonAnnotations {
            annotation.entity.isEnabled = !annotation.type.isHidden(in: mode,
                                                                    hidesAutoInFirstPerson: annotation.hidesAutoInFirstPerson)
        }
    }

    fileprivate func applyMaterialColor(_ color: SIMD4<Float>,
                                        type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                                        materialIndex: Int) {
        // A shader animating this color owns it in its own parameters, which
        // reach the GPU once per material via flushDirtyMaterialStates(). An
        // unclaimed color falls back below.
        if mutateAnimatableState(ofMaterial: materialIndex, { $0.setColor(color, for: type) }) {
            return
        }
        let vrmColor = VRMColor(simd: color)
        mapMaterials(ofMaterial: materialIndex) { $0.settingColor(vrmColor, for: type) }
    }

    fileprivate func applyTextureTransform(scale: SIMD2<Float>,
                                           offset: SIMD2<Float>,
                                           rotation: Float,
                                           materialIndex: Int) {
        // A shader animating the UV transform applies it itself from its
        // parameters; writing RealityKit's material-level transform too would
        // transform the primary UV twice. Everything else, fallback materials
        // included, uses the material-level transform.
        if mutateAnimatableState(ofMaterial: materialIndex, {
            $0.setTextureTransform(scale: scale, offset: offset, rotation: rotation)
        }) {
            return
        }
        mapMaterials(ofMaterial: materialIndex) {
            $0.settingTextureTransform(scale: scale, offset: offset, rotation: rotation)
        }
    }

    /// The key a clip is actually stored under. An expression named after a
    /// preset is that preset, which is how VRM 0.x models predating the presets
    /// name theirs.
    private func canonicalExpressionKey(for key: ExpressionKey) -> ExpressionKey? {
        expressionClips.canonicalKey(for: key)
    }

    /// Adds one clip's share of every morph target it binds. Expressions
    /// overlapping on a target sum up rather than overwrite.
    private func accumulate(_ bindings: [BlendShapeBinding],
                            weight: Float,
                            into morphWeights: inout [MorphBindingKey: Float]) {
        for binding in bindings {
            let key = MorphBindingKey(mesh: binding.mesh, targetIndex: binding.index)
            morphWeights[key, default: 0] += Float(binding.weight / 100.0) * weight
        }
    }

    /// Pushes the accumulated weights to the meshes, resetting every bound
    /// target no active clip touches and skipping the ones that did not move.
    private func flushMorphWeights(_ morphWeights: [MorphBindingKey: Float]) {
        for (key, binding) in morphBindingIndex {
            let weight = morphWeights[key] ?? 0
            guard appliedMorphWeights[key] != weight else { continue }
            appliedMorphWeights[key] = weight
            applyBlendShapeWeight(weight, targetIndex: binding.index, on: binding.mesh)
        }
    }

    private func applyExpressions() {
        let expressionWeights = expressionClips.effectiveWeights(of: expressionWeights)

        var morphWeights: [MorphBindingKey: Float] = [:]
        for (expressionKey, expressionWeight) in expressionWeights {
            guard let clip = expressionClips[expressionKey] else { continue }
            accumulate(clip.values, weight: expressionWeight, into: &morphWeights)
        }
        flushMorphWeights(morphWeights)

        var colors: [MaterialColorBindingKey: SIMD4<Float>] = [:]
        for (expressionKey, expressionWeight) in expressionWeights {
            for binding in materialColorClips[expressionKey] ?? [] {
                colors[binding.key, default: binding.baseValue] +=
                    (binding.targetValue - binding.baseValue) * expressionWeight
            }
        }
        for (key, binding) in colorBindingIndex {
            let color = colors[key] ?? binding.baseValue
            guard appliedMaterialColors[key] != color else { continue }
            appliedMaterialColors[key] = color
            applyMaterialColor(color, type: binding.type, materialIndex: binding.materialIndex)
        }

        var scales: [Int: SIMD2<Float>] = [:]
        var offsets: [Int: SIMD2<Float>] = [:]
        for (expressionKey, expressionWeight) in expressionWeights {
            for binding in textureTransformClips[expressionKey] ?? [] {
                scales[binding.materialIndex, default: binding.baseScale] +=
                    (binding.targetScale - binding.baseScale) * expressionWeight
                offsets[binding.materialIndex, default: binding.baseOffset] +=
                    (binding.targetOffset - binding.baseOffset) * expressionWeight
            }
        }
        for (materialIndex, binding) in transformBindingIndex {
            let scale = scales[materialIndex] ?? binding.baseScale
            let offset = offsets[materialIndex] ?? binding.baseOffset
            let applied = SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)
            guard appliedTextureTransforms[materialIndex] != applied else { continue }
            appliedTextureTransforms[materialIndex] = applied
            applyTextureTransform(scale: scale,
                                  offset: offset,
                                  rotation: binding.baseRotation,
                                  materialIndex: materialIndex)
        }

        flushDirtyMaterialStates()
    }

    /// Where one blend-shape target lives in a model entity's weight sets.
    private struct BlendShapeSlot {
        let modelEntity: ModelEntity
        /// (weight set, index within it) pairs the target writes to.
        let positions: [(set: Int, index: Int)]
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

    /// Resolves the target's weight-set positions once per mesh, replacing a
    /// blend-shape name lookup on every write.
    private func blendShapeSlots(targetIndex: Int, on mesh: Entity) -> [BlendShapeSlot] {
        let key = MorphBindingKey(mesh: mesh, targetIndex: targetIndex)
        if let cached = blendShapeSlotCache[key] {
            return cached
        }

        let targetName = "blendShape_\(targetIndex)"
        var slots: [BlendShapeSlot] = []
        for modelEntity in mesh.modelEntitiesInHierarchy {
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
        blendShapeSlotCache[key] = slots
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
private struct NodeConstraintBinding {
    let targetIndex: Int
    let sourceIndex: Int
    let descriptor: VRMNodeConstraintDescriptor
    let target: Entity
    let source: Entity
    let targetRestRotation: simd_quatf
    let sourceRestRotation: simd_quatf

    @MainActor
    init(targetIndex: Int,
         sourceIndex: Int,
         descriptor: VRMNodeConstraintDescriptor,
         target: Entity,
         source: Entity) {
        self.targetIndex = targetIndex
        self.sourceIndex = sourceIndex
        self.descriptor = descriptor
        self.target = target
        self.source = source
        self.targetRestRotation = target.utx.localRotation
        self.sourceRestRotation = source.utx.localRotation
    }

    @MainActor
    func apply() -> Bool {
        let rotation = VRMNodeConstraintRuntime.evaluate(
            descriptor,
            sourceRestRotation: sourceRestRotation,
            sourceLocalRotation: source.utx.localRotation,
            sourceWorldPosition: source.utx.position,
            destinationRestRotation: targetRestRotation,
            destinationParentWorldRotation: target.parent?.utx.rotation ?? quat_identity_float,
            destinationWorldPosition: target.utx.position
        )
        let current = target.utx.localRotation.vector
        guard current != rotation.vector, current != -rotation.vector else { return false }
        target.utx.setLocalRotation(rotation)
        return true
    }

}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
/// Identifies one morph target on one mesh entity. Used both to accumulate
/// expression weights and to cache where that target lives in the blend-shape
/// weight sets.
private struct MorphBindingKey: Hashable {
    let mesh: ObjectIdentifier
    let targetIndex: Int

    init(mesh: Entity, targetIndex: Int) {
        self.mesh = ObjectIdentifier(mesh)
        self.targetIndex = targetIndex
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
private struct MaterialColorBindingKey: Hashable {
    let materialIndex: Int
    let type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
private struct MaterialColorBinding {
    let materialIndex: Int
    let type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
    let targetValue: SIMD4<Float>
    let baseValue: SIMD4<Float>

    var key: MaterialColorBindingKey {
        MaterialColorBindingKey(materialIndex: materialIndex, type: type)
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
private struct TextureTransformBinding {
    let materialIndex: Int
    let baseScale: SIMD2<Float>
    let baseOffset: SIMD2<Float>
    let baseRotation: Float
    let targetScale: SIMD2<Float>
    let targetOffset: SIMD2<Float>
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
            // shadeColor / matcapColor / rimColor / outlineColor are MToon-only,
            // so they have no meaning on the PBR fallback material.
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
