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
    private var springBones = SpringBoneRig<Entity>()
    private var nodeConstraints = NodeConstraintRig<Entity>()
    // Determined by the clips alone, so built once at load time rather than on
    // every expression change.
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

    /// Registers the components and the system this entity relies on, exactly
    /// once per process. RealityKit instantiates a registered system for every
    /// scene, existing ones included, so registering on first use is enough.
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

    /// Also builds the copies `clone(recursive:)` returns, which inherit the
    /// ``VRMComponent`` but not the runtime bindings, so they only render.
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
    func setUpBlendShapes(nodes: [Entity?],
                          meshes: [Int: [EntityData.SceneMesh]],
                          loader: VRMEntityLoader) throws {
        switch vrm {
        case .v0(let vrm0):
            // A 0.x group is loaded as the expression it stands for, so the
            // runtime below drives both versions through one set of clips.
            for group in vrm0.blendShapeMaster.blendShapeGroups {
                let morphBindings: [BlendShapeBinding] = group.binds?
                    .flatMap { bind in
                        (meshes[bind.mesh] ?? []).map {
                            BlendShapeBinding(mesh: $0.entity, index: bind.index, weight: bind.weight)
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
                        // As above, a malformed bind only invalidates itself.
                        guard let base = try? currentTextureTransform(withMaterialIndex: bind.material,
                                                                      loader: loader) else {
                            Self.logger.warning("""
                            Skipping invalid TextureTransformBind. \
                            expression=\(expressionClip.name, privacy: .public) \
                            materialIndex=\(bind.material)
                            """)
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

    /// What each camera draws of each mesh. The `auto` cut is made as the meshes
    /// are built, so this only pairs it with the entity drawing it.
    func setUpFirstPerson(plan: VRMFirstPersonPlan,
                          nodes: [Entity?],
                          meshes: [Int: [EntityData.SceneMesh]]) {
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
                              loader: GLTFEntityLoader) throws {
        nodeConstraints = try NodeConstraintRig.make(vrm: vrm, gltfNodes: gltfNodes, hierarchy: hierarchy) {
            try loader.node(withNodeIndex: $0)
        }
    }

    func setUpSpringBones(loader: GLTFEntityLoader) throws {
        springBones = try SpringBoneRig.make(vrm: vrm) { try loader.node(withNodeIndex: $0) }
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
    /// ``VRMUpdateSystem`` calls this once per render frame, so set
    /// ``isAutomaticUpdateEnabled`` to `false` before driving the timing
    /// manually. The skin pose is re-solved only when a joint has moved, so
    /// posing a humanoid bone directly has to be followed by
    /// ``GLTFEntity/invalidateSkinPose()``.
    public func update(deltaTime: TimeInterval) {
        let deltaTime = max(0, deltaTime)
        // Skinning runs last so that this frame's constraint and spring-bone
        // poses reach the skinned meshes in the same frame they are solved.
        let movedJoints = nodeConstraints.apply()
        springBones.update(deltaTime: deltaTime)
        if !springBones.isEmpty || movedJoints {
            invalidateSkinPose()
        }
        flushSkinPoseIfNeeded()
    }

    public func setExpression(value: CGFloat, for key: ExpressionKey) {
        setExpressions([key: value])
    }

    /// Sets several expression weights and re-applies the result once. Prefer it
    /// over repeated ``setExpression(value:for:)`` calls when one frame changes
    /// more than one expression, since applying re-accumulates every active clip.
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
            // An `auto` mesh is cut rather than hidden, so the body below it stays.
            if annotation.type == .auto, applyFirstPersonCut(mode, to: annotation.entity) { continue }
            annotation.entity.isEnabled = !annotation.type.isHidden(in: mode,
                                                                    hidesAutoInFirstPerson: annotation.hidesAutoInFirstPerson)
        }
    }

    /// Draws `entity` with the triangles `mode` asks for, and says whether it was cut.
    private func applyFirstPersonCut(_ mode: FirstPersonRenderMode, to entity: Entity) -> Bool {
        var cut = false
        var stack = [entity]
        while let current = stack.popLast() {
            // The cut is stated on whatever holds one primitive: the model
            // entity, or the container its render passes share.
            guard let masked = current.components[FirstPersonMeshComponent.self] else {
                stack.append(contentsOf: current.children)
                continue
            }
            cut = true
            let mesh = mode == .firstPerson ? masked.firstPersonMesh : masked.thirdPersonMesh
            // Nothing left to draw, so what holds it goes instead.
            current.isEnabled = mesh != nil
            guard let mesh else { continue }
            for model in current.modelEntitiesInHierarchy {
                guard var component = model.components[ModelComponent.self] else { continue }
                component.mesh = mesh
                model.components.set(component)
            }
        }
        return cut
    }

    fileprivate func applyMaterialColor(_ color: SIMD4<Float>,
                                        type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                                        materialIndex: Int) {
        // A shader animating this color owns it in its own parameters. An
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
        // A shader animating the UV transform applies it from its own parameters;
        // writing the material-level transform too would transform the primary UV
        // twice. Everything else uses the material-level transform.
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
