#if canImport(RealityKit)
import CoreGraphics
import Foundation
import OSLog
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct VRMMaterialIndexComponent: Component {
    let materialIndex: Int
}

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
public final class VRMEntity: Entity {
    private static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "MToon")

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

    var blendShapeClips: [BlendShapeKey: BlendShapeClip] = [:]
    var expressionClips: [ExpressionKey: ExpressionClip] = [:]
    private var expressionWeights: [ExpressionKey: Float] = [:]
    private var materialColorClips: [ExpressionKey: [MaterialColorBinding]] = [:]
    private var textureTransformClips: [ExpressionKey: [TextureTransformBinding]] = [:]
    private var firstPersonAnnotations: [FirstPersonAnnotation] = []
    private var skinBindings: [SkinBinding] = []
    /// Everything the runtime tracks per glTF material. Keying this by material
    /// index — rather than copying it onto every entity — is what keeps the
    /// MToon parameter rows single-source.
    private struct MaterialRuntimeState {
        var modelEntities: [ModelEntity] = []
        var mtoonParameters: MToonMaterialParameters?
        var needsMToonParameterFlush = false
    }

    private var materialStates: [Int: MaterialRuntimeState] = [:]
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
    private var mtoonLightDirection = MToonMaterialParameters.defaultLightDirection
    private var mtoonLightColor = SIMD3<Float>(1, 1, 1)
    private var mtoonAmbientColor = SIMD3<Float>(0, 0, 0)

    struct SkinBinding {
        let modelEntity: ModelEntity
        let skeleton: MeshResource.Skeleton
        let jointEntities: [Entity]
    }

    /// Registers the components and the system this entity relies on. RealityKit
    /// instantiates registered systems for every scene, including scenes that
    /// already exist, so registering on first use is enough; `static let` runs
    /// the body exactly once.
    @MainActor private static let registerRealityKitTypes: Void = {
        VRMComponent.registerComponent()
        VRMUpdateComponent.registerComponent()
        VRMMaterialIndexComponent.registerComponent()
        VRMUpdateSystem.registerSystem()
    }()

    init(vrm: VRM) {
        super.init()
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

    func setUpHumanoid(nodes: [Entity?]) {
        switch vrm {
        case .v0:
            humanoid.setUp(humanoid: vrm.humanoid, nodes: nodes)
        case .v1(let vrm1):
            humanoid.setUp(humanoid: vrm1.humanoid, nodes: nodes)
        }
    }

    /// Called once per entity, right after its node hierarchy is built.
    func setUpBlendShapes(nodes: [Entity?], meshes: [Entity?], loader: VRMEntityLoader) throws {
        switch vrm {
        case .v0:
            blendShapeClips = vrm.blendShapeMaster.blendShapeGroups
                .map { group in
                    let blendShapeBinding: [BlendShapeBinding] = group.binds?
                        .compactMap {
                            guard meshes.indices.contains($0.mesh),
                                  let mesh = meshes[$0.mesh] else {
                                return nil
                            }
                            return BlendShapeBinding(mesh: mesh, index: $0.index, weight: $0.weight)
                        } ?? []
                    return BlendShapeClip(name: group.name,
                                          preset: BlendShapePreset(name: group.presetName),
                                          values: blendShapeBinding,
                                          isBinary: group.isBinary)
                }
                .reduce(into: [:]) { result, clip in
                    result[clip.key] = clip
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
                        guard let baseValue = try? loader.currentMaterialColor(withMaterialIndex: bind.material,
                                                                               type: bind.type) else {
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
                        guard let base = try? loader.currentTextureTransform(withMaterialIndex: bind.material) else {
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

        buildExpressionBindingIndexes()
    }

    /// Indexes every expression binding once, so `applyExpressions()` only
    /// accumulates weights instead of rediscovering the bindings each time.
    private func buildExpressionBindingIndexes() {
        for clip in expressionClips.values {
            for binding in clip.values {
                let key = MorphBindingKey(mesh: binding.mesh, targetIndex: binding.index)
                morphBindingIndex[key] = binding
            }
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

    func setUpFirstPerson(nodes: [Entity?], meshes: [Entity?]) {
        switch vrm {
        case .v0:
            firstPersonAnnotations = vrm.firstPerson.meshAnnotations.compactMap { annotation in
                guard meshes.indices.contains(annotation.mesh),
                      let mesh = meshes[annotation.mesh],
                      let type = FirstPersonAnnotationType(vrm0Flag: annotation.firstPersonFlag) else {
                    return nil
                }
                return FirstPersonAnnotation(entity: mesh,
                                             type: type,
                                             hidesAutoInFirstPerson: false)
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

    func setUpNodeConstraints(gltfNodes: [GLTF.Node], loader: VRMEntityLoader) throws {
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
        nodeConstraints = try NodeConstraintBinding.ordered(bindings)
    }

    func setUpSpringBones(loader: VRMEntityLoader) throws {
        var springBones: [VRMEntitySpringBone] = []
        switch vrm {
        case .v0:
            let secondaryAnimation = vrm.secondaryAnimation
            let allColliderGroups = try secondaryAnimation.colliderGroups.map {
                try VRMEntitySpringBoneColliderGroup(colliderGroup: $0, loader: loader)
            }
            for boneGroup in secondaryAnimation.boneGroups {
                guard !boneGroup.bones.isEmpty else { continue }
                let rootBones: [Entity] = try boneGroup.bones.compactMap { try loader.node(withNodeIndex: $0) }
                let centerNode = try? loader.node(withNodeIndex: boneGroup.center)
                let colliderGroups = boneGroup.colliderGroups.compactMap { index in
                    allColliderGroups.indices.contains(index) ? allColliderGroups[index] : nil
                }
                let springBone = VRMEntitySpringBone(center: centerNode,
                                                         rootBones: rootBones,
                                                         comment: boneGroup.comment,
                                                         stiffnessForce: Float(boneGroup.stiffiness),
                                                         gravityPower: Float(boneGroup.gravityPower),
                                                         gravityDir: SIMD3<Float>(Float(boneGroup.gravityDir.x), Float(boneGroup.gravityDir.y), Float(boneGroup.gravityDir.z)),
                                                         dragForce: Float(boneGroup.dragForce),
                                                         hitRadius: Float(boneGroup.hitRadius),
                                                         colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        case .v1(let vrm1):
            guard let springBone = vrm1.springBone else { break }
            for spring in springBone.springs ?? [] {
                let jointEntities = try spring.joints.compactMap { try loader.node(withNodeIndex: $0.node) }
                guard !jointEntities.isEmpty else { continue }
                let centerEntity = try spring.center.map { try loader.node(withNodeIndex: $0) }
                let colliderGroups = try spring.colliderGroups?.compactMap { groupIndex -> VRMEntitySpringBoneColliderGroup? in
                    guard let groups = springBone.colliderGroups,
                          groups.indices.contains(groupIndex) else {
                        return nil
                    }
                    return try VRMEntitySpringBoneColliderGroup(colliderGroup: groups[groupIndex],
                                                                springBone: springBone,
                                                                loader: loader)
                } ?? []
                let settings = Dictionary(uniqueKeysWithValues: zip(jointEntities, spring.joints).map { entity, joint in
                    (ObjectIdentifier(entity), VRMEntitySpringBone.JointSetting(joint: joint))
                })
                let springBone = VRMEntitySpringBone(center: centerEntity,
                                                     rootBones: [jointEntities[0]],
                                                     comment: spring.name,
                                                     jointChain: jointEntities,
                                                     jointSettings: settings,
                                                     colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        }
        self.springBones = springBones
    }

    func registerSkinBinding(modelEntity: ModelEntity,
                             skeleton: MeshResource.Skeleton,
                             jointEntities: [Entity]) {
        let binding = SkinBinding(modelEntity: modelEntity,
                                  skeleton: skeleton,
                                  jointEntities: jointEntities)
        skinBindings.append(binding)
        initializeSkinPose(for: binding)
    }

    /// Registers an entity as a renderer of `materialIndex`. The MToon parameter
    /// rows are resolved once per material, so every entity sharing it shares them.
    func registerMaterialBinding(modelEntity: ModelEntity, materialIndex: Int, loader: VRMEntityLoader) {
        if materialStates[materialIndex] == nil {
            materialStates[materialIndex] = MaterialRuntimeState(
                mtoonParameters: try? loader.mtoonParameters(withMaterialIndex: materialIndex)
            )
        }
        materialStates[materialIndex]?.modelEntities.append(modelEntity)
    }

    /// The MToon parameter rows a material renders with, or nil when it does
    /// not render as MToon.
    func mtoonParameters(forMaterialIndex index: Int) -> MToonMaterialParameters? {
        materialStates[index]?.mtoonParameters
    }

    /// Advances spring bones, node constraints, and skinning by one frame.
    ///
    /// ``VRMUpdateSystem`` calls this automatically once per render frame, so
    /// there is normally no need to call it. To drive the timing manually, set
    /// ``isAutomaticUpdateEnabled`` to `false` first — otherwise the model
    /// advances twice per frame.
    public func update(deltaTime: TimeInterval) {
        let deltaTime = max(0, deltaTime)
        // Skinning runs last so that this frame's constraint and spring-bone
        // poses reach the skinned meshes in the same frame they are solved.
        nodeConstraints.forEach { $0.apply() }
        springBones.forEach { $0.update(deltaTime: deltaTime) }
        updateSkinning()
    }

    /// Sets the explicit main light direction used by MToon CustomMaterial shaders.
    /// The vector points from the surface toward the light, so a `DirectionalLight`
    /// matching it is placed at `direction` and aimed at the model.
    public func setMToonLightDirection(_ direction: SIMD3<Float>) {
        let length = simd_length(direction)
        let normalized = length > 0.001 ? direction / length : MToonMaterialParameters.defaultLightDirection
        guard simd_distance(normalized, mtoonLightDirection) > 0.0001 else { return }
        mtoonLightDirection = normalized
        // The direction rides in custom.value rather than in a parameter row, so
        // it reaches the materials without rebuilding their packed texture — and
        // without clearing a rebuild an earlier row change is still waiting for.
        for materialIndex in materialStates.keys {
            guard var parameters = materialStates[materialIndex]?.mtoonParameters else { continue }
            parameters.lightDirection = normalized
            materialStates[materialIndex]?.mtoonParameters = parameters
            applyMToonParameters(parameters, ofMaterial: materialIndex, parameterTexture: nil)
        }
    }

    /// Sets the explicit main light color used by MToon CustomMaterial shaders. The default is white.
    public func setMToonLightColor(_ color: SIMD3<Float>) {
        guard color != mtoonLightColor else { return }
        mtoonLightColor = color
        updateMToonLightingRows()
    }

    /// Sets the explicit ambient color used by the MToon GI approximation. The default is black.
    public func setMToonAmbientColor(_ color: SIMD3<Float>) {
        guard color != mtoonAmbientColor else { return }
        mtoonAmbientColor = color
        updateMToonLightingRows()
    }

    private func updateSkinning() {
        // Bindings that share a skeleton and model world transform — a mesh and
        // its MToon outline twin, or primitives of the same skinned mesh —
        // resolve to identical joint transforms, so solve them once per frame.
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

    private func initializeSkinPose(for binding: SkinBinding) {
        let modelWorld = binding.modelEntity.transformMatrix(relativeTo: nil)
        setSkinPose(jointTransforms(for: binding, modelWorld: modelWorld), for: binding)
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
        // Each joint's world matrix is also its children's parent matrix, so
        // resolve them once instead of walking the ancestor chain twice.
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

    public func setBlendShape(value: CGFloat, for key: BlendShapeKey) {
        if case .v1 = vrm, let expressionKey = key.expressionKey {
            setExpression(value: value, for: expressionKey)
            return
        }
        guard let clip = blendShapeClips[key] else { return }
        let normalized = clip.normalizedWeight(Double(value))
        for binding in clip.values {
            let weight = Float(binding.weight / 100.0) * Float(normalized)
            applyBlendShapeWeight(weight, targetIndex: binding.index, on: binding.mesh)
        }
    }

    public func blendShape(for key: BlendShapeKey) -> CGFloat {
        if case .v1 = vrm, let expressionKey = key.expressionKey {
            return expression(for: expressionKey)
        }
        guard let clip = blendShapeClips[key],
              let binding = clip.values.first else { return 0 }
        return CGFloat(readBlendShapeWeight(targetIndex: binding.index, on: binding.mesh))
    }

    public func setExpression(value: CGFloat, for key: ExpressionKey) {
        guard storeExpressionWeight(value, for: key) else { return }
        applyExpressions()
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
        let normalized = clip.normalizedWeight(Double(value))
        let weight = normalized > 0 ? Float(normalized) : nil
        guard weight != expressionWeights[key] else { return false }
        if let weight {
            expressionWeights[key] = weight
        } else {
            expressionWeights.removeValue(forKey: key)
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
        // MToon owns its colors in the parameter rows; the packed texture is
        // rebuilt once per material by flushDirtyMToonParameters().
        if mutateMToonParameters(ofMaterial: materialIndex, { $0.setColor(color, for: type) }) {
            return
        }
        let vrmColor = VRMColor(simd: color)
        forEachModelEntity(ofMaterial: materialIndex) { component in
            component.materials = component.materials.map { $0.settingColor(vrmColor, for: type) }
        }
    }

    fileprivate func applyTextureTransform(scale: SIMD2<Float>,
                                           offset: SIMD2<Float>,
                                           rotation: Float,
                                           materialIndex: Int) {
        // MToon applies the UV transform in its own shader from the parameter
        // rows; writing RealityKit's material-level transform too would
        // transform the primary UV twice. Fallback materials have no such
        // shader, so they use the material-level transform.
        if mutateMToonParameters(ofMaterial: materialIndex, {
            $0.setTextureTransform(scale: scale, offset: offset, rotation: rotation)
        }) {
            return
        }
        forEachModelEntity(ofMaterial: materialIndex) { component in
            component.materials = component.materials.map {
                $0.settingTextureTransform(scale: scale, offset: offset, rotation: rotation)
            }
        }
    }

    // MARK: - MToon runtime state
    //
    // MToon parameters describe a *material*, not an entity, so they are stored
    // once per material index and pushed to every entity that renders with it.
    // visionOS has no `CustomMaterial`, so no material has them and these all
    // no-op there without platform conditionals of their own.

    /// Edits a material's MToon parameter rows, marking its packed texture for
    /// rebuild. Returns false when the material does not render as MToon, which
    /// is the caller's cue to fall back to the RealityKit material properties.
    @discardableResult
    private func mutateMToonParameters(ofMaterial materialIndex: Int,
                                       _ mutate: (inout MToonMaterialParameters) -> Void) -> Bool {
        guard var parameters = materialStates[materialIndex]?.mtoonParameters else { return false }
        mutate(&parameters)
        materialStates[materialIndex]?.mtoonParameters = parameters
        materialStates[materialIndex]?.needsMToonParameterFlush = true
        return true
    }

    /// Rebuilds the packed parameter texture once per material whose rows
    /// changed, instead of once per binding that touched it.
    private func flushDirtyMToonParameters() {
        for (materialIndex, state) in materialStates where state.needsMToonParameterFlush {
            guard let parameters = state.mtoonParameters,
                  let parameterTexture = parameterTextureResource(for: parameters) else {
                // The GPU still holds the previous values, so the material stays
                // dirty and the next flush retries building its texture.
                continue
            }
            applyMToonParameters(parameters, ofMaterial: materialIndex, parameterTexture: parameterTexture)
            materialStates[materialIndex]?.needsMToonParameterFlush = false
        }
    }

    /// Pushes the entity-level light and ambient colors into every MToon
    /// material's parameter rows. They are packed into the parameter texture, so
    /// they take the same dirty-and-flush path as expression-driven row changes.
    private func updateMToonLightingRows() {
        for materialIndex in materialStates.keys {
            mutateMToonParameters(ofMaterial: materialIndex) { parameters in
                parameters.lightColor = SIMD4<Float>(mtoonLightColor, 1)
                parameters.ambientColor = SIMD4<Float>(mtoonAmbientColor, 1)
            }
        }
        flushDirtyMToonParameters()
    }

    private func applyMToonParameters(_ parameters: MToonMaterialParameters,
                                      ofMaterial materialIndex: Int,
                                      parameterTexture: TextureResource?) {
        forEachModelEntity(ofMaterial: materialIndex) { component in
            component.materials = component.materials.map {
                applyingMToonParameters(parameters, to: $0, parameterTexture: parameterTexture)
            }
        }
    }

    /// Applies `edit` to the `ModelComponent` of every entity rendering with
    /// `materialIndex`, writing the component back.
    private func forEachModelEntity(ofMaterial materialIndex: Int,
                                    _ edit: (inout ModelComponent) -> Void) {
        guard let modelEntities = materialStates[materialIndex]?.modelEntities else { return }
        for modelEntity in modelEntities {
            guard var component = modelEntity.components[ModelComponent.self] else { continue }
            edit(&component)
            modelEntity.components.set(component)
        }
    }

    /// MToon parameters live on `CustomMaterial`, which visionOS does not have,
    /// so this is the single platform boundary of the runtime update path.
    private func applyingMToonParameters(_ parameters: MToonMaterialParameters,
                                         to material: any Material,
                                         parameterTexture: TextureResource?) -> any Material {
#if os(visionOS)
        return material
#else
        guard var material = material as? CustomMaterial else { return material }
        material.custom.value = parameters.customValue
        if let parameterTexture {
            material.custom.texture = CustomMaterial.Texture(parameterTexture)
        }
        return material
#endif
    }

    /// Packs the parameter rows into one GPU texture. Callers build it once per
    /// material and share it across every entity that renders with it.
    private func parameterTextureResource(for parameters: MToonMaterialParameters) -> TextureResource? {
        do {
            return try parameters.textureResource()
        } catch {
            Self.logger.error("Failed to update MToon parameter texture: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func canonicalExpressionKey(for key: ExpressionKey) -> ExpressionKey? {
        if expressionClips[key] != nil { return key }
        if let legacyKey = key.legacyBlendShapeKey,
           let expressionKey = legacyKey.expressionKey,
           expressionClips[expressionKey] != nil {
            return expressionKey
        }
        return nil
    }

    /// Applies VRMC_vrm expression overrides to the input weights. A binary
    /// expression is suppressed outright rather than scaled, having no partial
    /// state.
    private func effectiveExpressionWeights() -> [ExpressionKey: Float] {
        var states = ExpressionOverrideStates()
        for (expressionKey, weight) in expressionWeights {
            guard let clip = expressionClips[expressionKey] else { continue }
            states.accumulate(clip, weight: Double(weight), excluding: expressionKey.overrideGroup)
        }
        guard states.isSuppressingAnyGroup else { return expressionWeights }

        var result: [ExpressionKey: Float] = [:]
        result.reserveCapacity(expressionWeights.count)
        for (expressionKey, weight) in expressionWeights {
            let state = expressionKey.overrideGroup.map { states[$0] }
            guard let state, state.isSuppressing else {
                result[expressionKey] = weight
                continue
            }
            let isBinary = expressionClips[expressionKey]?.isBinary ?? false
            let overridden = isBinary ? 0 : weight * Float(state.factor)
            if overridden > 0 {
                result[expressionKey] = overridden
            }
        }
        return result
    }

    private func applyExpressions() {
        let expressionWeights = effectiveExpressionWeights()

        var morphWeights: [MorphBindingKey: Float] = [:]
        for (expressionKey, expressionWeight) in expressionWeights {
            guard let clip = expressionClips[expressionKey] else { continue }
            for binding in clip.values {
                let key = MorphBindingKey(mesh: binding.mesh, targetIndex: binding.index)
                morphWeights[key, default: 0] += Float(binding.weight / 100.0) * expressionWeight
            }
        }
        for (key, binding) in morphBindingIndex {
            let weight = morphWeights[key] ?? 0
            guard appliedMorphWeights[key] != weight else { continue }
            appliedMorphWeights[key] = weight
            applyBlendShapeWeight(weight, targetIndex: binding.index, on: binding.mesh)
        }

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

        flushDirtyMToonParameters()
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

    private func readBlendShapeWeight(targetIndex: Int, on mesh: Entity) -> Float {
        let targetName = "blendShape_\(targetIndex)"
        for modelEntity in mesh.modelEntitiesInHierarchy {
            let weights = modelEntity.blendWeights
            if let firstSet = weights.first, targetIndex < firstSet.count {
                let names = modelEntity.blendWeightNames
                if let firstNames = names.first,
                   let nameIndex = firstNames.firstIndex(of: targetName),
                   nameIndex < firstSet.count {
                    return firstSet[nameIndex]
                }
                return firstSet[targetIndex]
            }
        }
        return 0
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
    func apply() {
        target.utx.localRotation = VRMNodeConstraintRuntime.evaluate(
            descriptor,
            sourceRestRotation: sourceRestRotation,
            sourceLocalRotation: source.utx.localRotation,
            sourceWorldPosition: source.utx.position,
            destinationRestRotation: targetRestRotation,
            destinationParentWorldRotation: target.parent?.utx.rotation ?? quat_identity_float,
            destinationWorldPosition: target.utx.position
        )
    }

    static func ordered(_ bindings: [NodeConstraintBinding]) throws -> [NodeConstraintBinding] {
        var byTargetIndex: [Int: NodeConstraintBinding] = [:]
        for binding in bindings {
            if byTargetIndex[binding.targetIndex] != nil {
                throw VRMError._dataInconsistent("Multiple constraints targeting the same node \(binding.targetIndex)")
            }
            byTargetIndex[binding.targetIndex] = binding
        }
        var states: [Int: VisitState] = [:]
        var result: [NodeConstraintBinding] = []

        func visit(_ binding: NodeConstraintBinding) throws {
            switch states[binding.targetIndex] {
            case .done:
                return
            case .visiting:
                throw VRMError._dataInconsistent("VRMC_node_constraint circular dependency detected at node \(binding.targetIndex)")
            case .none:
                break
            }

            states[binding.targetIndex] = .visiting
            if let dependency = byTargetIndex[binding.sourceIndex] {
                try visit(dependency)
            }
            states[binding.targetIndex] = .done
            result.append(binding)
        }

        for binding in bindings {
            try visit(binding)
        }
        return result
    }

    private enum VisitState {
        case visiting
        case done
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
