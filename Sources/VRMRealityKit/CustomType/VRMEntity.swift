#if canImport(RealityKit)
import CoreGraphics
import Foundation
import OSLog
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct BlendShapeNormalTangentComponent: Component {
    let baseNormals: [SIMD3<Float>]
    let baseTangents: [SIMD3<Float>]
    let normalOffsets: [[SIMD3<Float>]]
    let tangentOffsets: [[SIMD3<Float>]]
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct VRMMaterialIndexComponent: Component {
    let materialIndex: Int
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class VRMEntity {
    private static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "MToon")

    public let vrm: VRM
    public let entity: Entity
    public let humanoid = Humanoid()

    private let enableNormalTangentBlendShape = false

    var blendShapeClips: [BlendShapeKey: BlendShapeClip] = [:]
    var expressionClips: [ExpressionKey: ExpressionClip] = [:]
    private var materialColorClips: [ExpressionKey: [MaterialColorBinding]] = [:]
    private var textureTransformClips: [ExpressionKey: [TextureTransformBinding]] = [:]
    private var firstPersonAnnotations: [FirstPersonAnnotation] = []
    private var skinBindings: [SkinBinding] = []
    private var modelEntitiesByMaterialIndex: [Int: [ModelEntity]] = [:]
    private var springBones: [VRMEntitySpringBone] = []
    private var nodeConstraints: [NodeConstraintBinding] = []
    private var mtoonLightDirection = MToonMaterialParameters.defaultLightDirection
    private var mtoonLightColor = SIMD3<Float>(1, 1, 1)
    private var mtoonAmbientColor = SIMD3<Float>(0, 0, 0)
    private var mtoonElapsedTime: Float = 0
    private var lastUpdateTime: TimeInterval?

    struct SkinBinding {
        let modelEntity: ModelEntity
        let skeleton: MeshResource.Skeleton
        let jointEntities: [Entity]
    }

    init(vrm: VRM) {
        self.vrm = vrm
        self.entity = Entity()
    }

    func setUpHumanoid(nodes: [Entity?]) {
        switch vrm {
        case .v0:
            humanoid.setUp(humanoid: vrm.humanoid, nodes: nodes)
        case .v1(let vrm1):
            humanoid.setUp(humanoid: vrm1.humanoid, nodes: nodes)
        }
    }

    func setUpBlendShapes(nodes: [Entity?], meshes: [Entity?], loader: VRMEntityLoader) throws {
        blendShapeClips = [:]
        expressionClips = [:]
        materialColorClips = [:]
        textureTransformClips = [:]

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
                                                 isBinary: expressionClip.expression.isBinary ?? false)
                expressionClips[runtimeClip.key] = runtimeClip

                let colorBindings: [MaterialColorBinding] = try expressionClip.expression.materialColorBinds?
                    .compactMap { bind in
                        guard bind.targetValue.count >= 3 else { return nil }
                        return MaterialColorBinding(materialIndex: bind.material,
                                                    type: bind.type,
                                                    targetValue: SIMD4<Float>(bind.targetValue, default: 1.0),
                                                    baseValue: try loader.currentMaterialColor(withMaterialIndex: bind.material,
                                                                                               type: bind.type))
                    } ?? []
                if !colorBindings.isEmpty {
                    materialColorClips[runtimeClip.key] = colorBindings
                }

                let transformBindings: [TextureTransformBinding] = expressionClip.expression.textureTransformBinds?
                    .compactMap { bind in
                        guard let material = try? loader.material(withMaterialIndex: bind.material) else { return nil }
                        let base = material.currentTextureTransform
                        return TextureTransformBinding(materialIndex: bind.material,
                                                       baseScale: base.scale,
                                                       baseOffset: base.offset,
                                                       targetScale: SIMD2<Float>(bind.scale, default: 1.0),
                                                       targetOffset: SIMD2<Float>(bind.offset, default: 0.0))
                    } ?? []
                if !transformBindings.isEmpty {
                    textureTransformClips[runtimeClip.key] = transformBindings
                }
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

    func registerMaterialBinding(modelEntity: ModelEntity, materialIndex: Int) {
        modelEntitiesByMaterialIndex[materialIndex, default: []].append(modelEntity)
    }

    public func update(at time: TimeInterval) {
        let deltaTime = lastUpdateTime.map { max(0, time - $0) } ?? 0
        lastUpdateTime = time

        updateMToonRuntime(deltaTime: Float(deltaTime))
        nodeConstraints.forEach { $0.apply() }
        updateSkinning()
        springBones.forEach { $0.update(deltaTime: deltaTime) }
    }

    public func setMToonLightDirection(_ direction: SIMD3<Float>) {
        let length = simd_length(direction)
        mtoonLightDirection = length > 0.001 ? direction / length : MToonMaterialParameters.defaultLightDirection
        updateMToonRuntime(deltaTime: 0)
    }

    /// Sets the explicit main light color used by MToon CustomMaterial shaders. The default is white.
    public func setMToonLightColor(_ color: SIMD3<Float>) {
        mtoonLightColor = color
        updateMToonLightingParameters()
    }

    /// Sets the explicit ambient color used by the MToon GI approximation. The default is black.
    public func setMToonAmbientColor(_ color: SIMD3<Float>) {
        mtoonAmbientColor = color
        updateMToonLightingParameters()
    }

    private func updateSkinning() {
        for binding in skinBindings {
            updateSkinPose(for: binding)
        }
    }

    private func initializeSkinPose(for binding: SkinBinding) {
        let transforms = jointTransforms(for: binding)
        var pose = SkeletalPose(id: binding.skeleton.id, from: binding.skeleton)
        pose.jointTransforms = transforms

        var component = binding.modelEntity.components[SkeletalPosesComponent.self] ?? SkeletalPosesComponent(poses: [pose])
        component.poses[pose.id] = pose
        component.poses.default = pose
        binding.modelEntity.components.set(component)
    }

    private func updateSkinPose(for binding: SkinBinding) {
        let transforms = jointTransforms(for: binding)
        guard var component = binding.modelEntity.components[SkeletalPosesComponent.self] else {
            initializeSkinPose(for: binding)
            return
        }

        if var pose = component.poses[binding.skeleton.id] ?? component.poses.default {
            pose.jointTransforms = transforms
            component.poses[pose.id] = pose
            component.poses.default = pose
        } else {
            var pose = SkeletalPose(id: binding.skeleton.id, from: binding.skeleton)
            pose.jointTransforms = transforms
            component.poses[pose.id] = pose
            component.poses.default = pose
        }

        binding.modelEntity.components.set(component)
    }

    private func jointTransforms(for binding: SkinBinding) -> JointTransforms {
        let jointEntities = binding.jointEntities
        let joints = binding.skeleton.joints
        var transforms: [Transform] = []
        transforms.reserveCapacity(jointEntities.count)

        let modelWorld = binding.modelEntity.transformMatrix(relativeTo: nil)
        let modelWorldInverse = simd_inverse(modelWorld)

        for index in 0..<jointEntities.count {
            let jointEntity = jointEntities[index]
            let jointWorld = jointEntity.transformMatrix(relativeTo: nil)
            let localMatrix: simd_float4x4
            if index < joints.count, let parentIndex = joints[index].parentIndex, parentIndex < jointEntities.count {
                let parentWorld = jointEntities[parentIndex].transformMatrix(relativeTo: nil)
                localMatrix = simd_mul(simd_inverse(parentWorld), jointWorld)
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
        let normalized = max(0.0, min(1.0, clip.isBinary ? round(value) : value))
        for binding in clip.values {
            let weight = Float(binding.weight / 100.0) * Float(normalized)
            applyBlendShapeWeight(weight, targetIndex: binding.index, on: binding.mesh)
        }
        if enableNormalTangentBlendShape {
            var meshesToUpdate: [Entity] = []
            var seenMeshes = Set<ObjectIdentifier>()
            for binding in clip.values {
                let meshID = ObjectIdentifier(binding.mesh)
                if seenMeshes.insert(meshID).inserted {
                    meshesToUpdate.append(binding.mesh)
                }
            }
            for mesh in meshesToUpdate {
                updateBlendShapeNormalsAndTangents(on: mesh)
            }
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
        guard let clip = expressionClip(for: key) else { return }
        let normalized = max(0.0, min(1.0, clip.isBinary ? round(value) : value))
        for binding in clip.values {
            let weight = Float(binding.weight / 100.0) * Float(normalized)
            applyBlendShapeWeight(weight, targetIndex: binding.index, on: binding.mesh)
        }
        for binding in materialColorClip(for: key) {
            binding.apply(value: Float(normalized), on: self)
        }
        for binding in textureTransformClip(for: key) {
            binding.apply(value: Float(normalized), on: self)
        }
    }

    public func expression(for key: ExpressionKey) -> CGFloat {
        guard let clip = expressionClip(for: key),
              let binding = clip.values.first else { return 0 }
        return CGFloat(readBlendShapeWeight(targetIndex: binding.index, on: binding.mesh))
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
        guard let models = modelEntitiesByMaterialIndex[materialIndex] else { return }
        let vrmColor = VRMColor(simd: color)
        for modelEntity in models {
            guard var component = modelEntity.components[ModelComponent.self] else { continue }
            if updateMToonColor(color, type: type, on: modelEntity, modelComponent: &component) {
                modelEntity.components.set(component)
                continue
            }
            component.materials = component.materials.map { material in
                material.settingColor(vrmColor, for: type)
            }
            modelEntity.components.set(component)
        }
    }

    fileprivate func applyTextureTransform(scale: SIMD2<Float>,
                                           offset: SIMD2<Float>,
                                           materialIndex: Int) {
        guard let models = modelEntitiesByMaterialIndex[materialIndex] else { return }
        for modelEntity in models {
            guard var component = modelEntity.components[ModelComponent.self] else { continue }
            component.materials = component.materials.map { material in
                material.settingTextureTransform(scale: scale, offset: offset)
            }
            modelEntity.components.set(component)
        }
    }

    private func updateMToonRuntime(deltaTime: Float) {
#if !os(visionOS)
        mtoonElapsedTime += deltaTime
        for modelEntity in modelEntities(in: entity) {
            guard var state = modelEntity.components[MToonMaterialParametersComponent.self],
                  var component = modelEntity.components[ModelComponent.self] else { continue }
            state.parameters.lightDirection = mtoonLightDirection
            state.parameters.elapsedTime = mtoonElapsedTime
            applyMToonParameters(state.parameters, to: &component, updateParameterTexture: false)
            modelEntity.components.set(state)
            modelEntity.components.set(component)
        }
#endif
    }

    private func updateMToonLightingParameters() {
#if !os(visionOS)
        for modelEntity in modelEntities(in: entity) {
            guard var state = modelEntity.components[MToonMaterialParametersComponent.self],
                  var component = modelEntity.components[ModelComponent.self] else { continue }
            state.parameters.lightColor = SIMD4<Float>(mtoonLightColor.x, mtoonLightColor.y, mtoonLightColor.z, 1)
            state.parameters.ambientColor = SIMD4<Float>(mtoonAmbientColor.x, mtoonAmbientColor.y, mtoonAmbientColor.z, 1)
            state.parameters.lightDirection = mtoonLightDirection
            state.parameters.elapsedTime = mtoonElapsedTime
            applyMToonParameters(state.parameters, to: &component, updateParameterTexture: true)
            modelEntity.components.set(state)
            modelEntity.components.set(component)
        }
#endif
    }

    private func updateMToonColor(_ color: SIMD4<Float>,
                                  type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                                  on modelEntity: ModelEntity,
                                  modelComponent: inout ModelComponent) -> Bool {
#if os(visionOS)
        return false
#else
        guard var state = modelEntity.components[MToonMaterialParametersComponent.self] else { return false }
        guard state.parameters.setColor(color, for: type) else { return false }
        state.parameters.lightColor = SIMD4<Float>(mtoonLightColor.x, mtoonLightColor.y, mtoonLightColor.z, 1)
        state.parameters.ambientColor = SIMD4<Float>(mtoonAmbientColor.x, mtoonAmbientColor.y, mtoonAmbientColor.z, 1)
        state.parameters.lightDirection = mtoonLightDirection
        state.parameters.elapsedTime = mtoonElapsedTime
        applyMToonParameters(state.parameters, to: &modelComponent, updateParameterTexture: true)
        modelEntity.components.set(state)
        return true
#endif
    }

#if !os(visionOS)
    private func applyMToonParameters(_ parameters: MToonMaterialParameters,
                                      to component: inout ModelComponent,
                                      updateParameterTexture: Bool) {
        component.materials = component.materials.map { material in
            guard var material = material as? CustomMaterial else { return material }
            material.custom.value = parameters.customValue
            if updateParameterTexture {
                do {
                    material.custom.texture = CustomMaterial.Texture(try parameters.textureResource())
                } catch {
                    Self.logger.error("Failed to update MToon parameter texture: \(error.localizedDescription, privacy: .public)")
                }
            }
            return material
        }
    }
#endif

    private func expressionClip(for key: ExpressionKey) -> ExpressionClip? {
        if let clip = expressionClips[key] { return clip }
        if let legacyKey = key.legacyBlendShapeKey,
           let expressionKey = legacyKey.expressionKey {
            return expressionClips[expressionKey]
        }
        return nil
    }

    private func materialColorClip(for key: ExpressionKey) -> [MaterialColorBinding] {
        if let clip = materialColorClips[key] { return clip }
        if let legacyKey = key.legacyBlendShapeKey,
           let expressionKey = legacyKey.expressionKey {
            return materialColorClips[expressionKey] ?? []
        }
        return []
    }

    private func textureTransformClip(for key: ExpressionKey) -> [TextureTransformBinding] {
        if let clip = textureTransformClips[key] { return clip }
        if let legacyKey = key.legacyBlendShapeKey,
           let expressionKey = legacyKey.expressionKey {
            return textureTransformClips[expressionKey] ?? []
        }
        return []
    }

    private func modelEntities(in root: Entity) -> [ModelEntity] {
        var result: [ModelEntity] = []
        var stack: [Entity] = [root]
        while let entity = stack.popLast() {
            if let modelEntity = entity as? ModelEntity {
                result.append(modelEntity)
            }
            stack.append(contentsOf: entity.children)
        }
        return result
    }

    private func applyBlendShapeWeight(_ weight: Float, targetIndex: Int, on mesh: Entity) {
        let targetName = "blendShape_\(targetIndex)"
        let models = modelEntities(in: mesh)
        for modelEntity in models {
            ensureBlendShapeComponent(on: modelEntity)
            var weights = modelEntity.blendWeights
            let names = modelEntity.blendWeightNames
            guard !weights.isEmpty else { continue }
            var didSet = false
            if !names.isEmpty {
                for setIndex in names.indices {
                    if let nameIndex = names[setIndex].firstIndex(of: targetName),
                       nameIndex < weights[setIndex].count {
                        weights[setIndex][nameIndex] = weight
                        didSet = true
                    }
                }
            }
            if !didSet {
                for setIndex in weights.indices {
                    guard targetIndex < weights[setIndex].count else { continue }
                    weights[setIndex][targetIndex] = weight
                }
            }
            modelEntity.blendWeights = weights
        }
    }

    private func updateBlendShapeNormalsAndTangents(on mesh: Entity) {
        for modelEntity in modelEntities(in: mesh) {
            applyNormalTangentMorphs(on: modelEntity)
        }
    }

    private func applyNormalTangentMorphs(on modelEntity: ModelEntity) {
        guard let component = modelEntity.components[BlendShapeNormalTangentComponent.self] else { return }
        let hasNormalOffsets = !component.normalOffsets.isEmpty
        let hasTangentOffsets = !component.tangentOffsets.isEmpty
        guard hasNormalOffsets || hasTangentOffsets else { return }

        let normals = hasNormalOffsets
            ? applyOffsets(base: component.baseNormals,
                           offsets: component.normalOffsets,
                           weights: blendShapeWeights(for: modelEntity,
                                                      targetCount: component.normalOffsets.count))
            : nil
        let tangents = hasTangentOffsets
            ? applyOffsets(base: component.baseTangents,
                           offsets: component.tangentOffsets,
                           weights: blendShapeWeights(for: modelEntity,
                                                      targetCount: component.tangentOffsets.count))
            : nil
        guard normals != nil || tangents != nil else { return }
        guard let model = modelEntity.components[ModelComponent.self] else { return }
        updateMeshBuffers(mesh: model.mesh, normals: normals, tangents: tangents)
    }

    private func blendShapeWeights(for modelEntity: ModelEntity, targetCount: Int) -> [Float] {
        guard let firstSet = modelEntity.blendWeights.first else {
            return Array(repeating: 0, count: targetCount)
        }
        var result = Array(repeating: Float(0), count: targetCount)
        let names = modelEntity.blendWeightNames.first ?? []
        if !names.isEmpty, names.count == firstSet.count {
            for (index, name) in names.enumerated() {
                guard let targetIndex = parseBlendShapeIndex(from: name),
                      targetIndex < targetCount,
                      index < firstSet.count else { continue }
                result[targetIndex] = firstSet[index]
            }
        } else {
            let count = min(targetCount, firstSet.count)
            for index in 0..<count {
                result[index] = firstSet[index]
            }
        }
        return result
    }

    private func parseBlendShapeIndex(from name: String) -> Int? {
        let prefix = "blendShape_"
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    private func applyOffsets(base: [SIMD3<Float>],
                              offsets: [[SIMD3<Float>]],
                              weights: [Float]) -> [SIMD3<Float>]? {
        guard !base.isEmpty, !offsets.isEmpty else { return nil }
        guard offsets.count == weights.count else { return nil }
        guard offsets.allSatisfy({ $0.count == base.count }) else { return nil }

        var result = base
        for targetIndex in 0..<offsets.count {
            let weight = weights[targetIndex]
            guard weight != 0 else { continue }
            let targetOffsets = offsets[targetIndex]
            for i in 0..<result.count {
                result[i] += targetOffsets[i] * weight
            }
        }
        return result
    }

    private func updateMeshBuffers(mesh: MeshResource,
                                   normals: [SIMD3<Float>]?,
                                   tangents: [SIMD3<Float>]?) {
        guard normals != nil || tangents != nil else { return }
        var contents = mesh.contents
        var updatedModels = MeshModelCollection()
        for model in contents.models {
            var model = model
            var updatedParts = MeshPartCollection()
            for part in model.parts {
                var part = part
                let vertexCount = part.positions.count
                if let normals, !normals.isEmpty, normals.count == vertexCount {
                    part.normals = MeshBuffer(normals)
                }
                if let tangents, !tangents.isEmpty, tangents.count == vertexCount {
                    part.tangents = MeshBuffer(tangents)
                }
                updatedParts.insert(part)
            }
            model.parts = updatedParts
            updatedModels.insert(model)
        }
        contents.models = updatedModels
        try? mesh.replace(with: contents)
    }

    private func readBlendShapeWeight(targetIndex: Int, on mesh: Entity) -> Float {
        let targetName = "blendShape_\(targetIndex)"
        for modelEntity in modelEntities(in: mesh) {
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
private struct MaterialColorBinding {
    let materialIndex: Int
    let type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
    let targetValue: SIMD4<Float>
    let baseValue: SIMD4<Float>

    @MainActor
    func apply(value: Float, on entity: VRMEntity) {
        entity.applyMaterialColor(baseValue + (targetValue - baseValue) * value,
                                  type: type,
                                  materialIndex: materialIndex)
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
private struct TextureTransformBinding {
    let materialIndex: Int
    let baseScale: SIMD2<Float>
    let baseOffset: SIMD2<Float>
    let targetScale: SIMD2<Float>
    let targetOffset: SIMD2<Float>

    @MainActor
    func apply(value: Float, on entity: VRMEntity) {
        let scale = baseScale + (targetScale - baseScale) * value
        let offset = baseOffset + (targetOffset - baseOffset) * value
        entity.applyTextureTransform(scale: scale,
                                     offset: offset,
                                     materialIndex: materialIndex)
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

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension Material {
    var currentTextureTransform: MaterialParameterTypes.TextureCoordinateTransform {
        switch self {
        case let material as UnlitMaterial:
            return material.textureCoordinateTransform
#if !os(visionOS)
        case let material as CustomMaterial:
            return material.textureCoordinateTransform
#endif
        case let material as PhysicallyBasedMaterial:
            return material.textureCoordinateTransform
        default:
            return MaterialParameterTypes.TextureCoordinateTransform()
        }
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
#if !os(visionOS)
        case let material as CustomMaterial:
            switch type {
            case .color:
                return material.baseColor.tint.simd
            case .rimColor:
                return material.emissiveColor.color.simd
            case .emissionColor, .shadeColor, .matcapColor, .outlineColor:
                return SIMD4<Float>(1, 1, 1, 1)
            }
#endif
        case let material as PhysicallyBasedMaterial:
            switch type {
            case .color:
                return material.baseColor.tint.simd
            case .emissionColor:
                return material.emissiveColor.color.simd
            case .matcapColor, .rimColor:
                return material.emissiveColor.color.simd
            case .shadeColor, .outlineColor:
                return SIMD4<Float>(1, 1, 1, 1)
            }
        default:
            return SIMD4<Float>(1, 1, 1, 1)
        }
    }

    func settingTextureTransform(scale: SIMD2<Float>, offset: SIMD2<Float>) -> Material {
        let transform = MaterialParameterTypes.TextureCoordinateTransform(offset: offset, scale: scale)
        switch self {
        case var material as UnlitMaterial:
            material.textureCoordinateTransform = transform
            return material
#if !os(visionOS)
        case var material as CustomMaterial:
            material.textureCoordinateTransform = transform
            return material
#endif
        case var material as PhysicallyBasedMaterial:
            material.textureCoordinateTransform = transform
            return material
        default:
            return self
        }
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
#if !os(visionOS)
        case var material as CustomMaterial:
            switch type {
            case .color:
                material.baseColor.tint = color
            case .rimColor:
                material.emissiveColor.color = color
            case .shadeColor, .emissionColor, .matcapColor, .outlineColor:
                break
            }
            return material
#endif
        case var material as PhysicallyBasedMaterial:
            switch type {
            case .color:
                material.baseColor.tint = color
            case .emissionColor:
                material.emissiveColor.color = color
            case .matcapColor, .rimColor:
                material.emissiveColor.color = color
            case .shadeColor, .outlineColor:
                break
            }
            return material
        default:
            return self
        }
    }

}
#endif
