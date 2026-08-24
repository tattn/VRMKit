import SceneKit
import simd
import VRMKit
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
open class VRMNode: SCNNode {
    public let vrm: VRM
    public let humanoid = Humanoid()
    private var lastUpdateTime: TimeInterval?
    private var springBones: [VRMSpringBone] = []

    var expressionClips: [ExpressionKey: ExpressionClip] = [:]
    private var expressionWeights: [ExpressionKey: CGFloat] = [:]
    private var materialColorClips: [ExpressionKey: [MaterialColorBinding]] = [:]
    private var textureTransformClips: [ExpressionKey: [TextureTransformBinding]] = [:]
    // Every binding any expression holds, so that a target no active
    // expression touches goes back to what it was rather than staying where
    // the last expression to drive it left it.
    private var morphBindings: [MorphBindingKey: BlendShapeBinding] = [:]
    private var colorBindings: [MaterialColorBindingKey: MaterialColorBinding] = [:]
    private var transformBindings: [ObjectIdentifier: TextureTransformBinding] = [:]
    private var firstPersonAnnotations: [FirstPersonAnnotation] = []
    private var nodeConstraints: [NodeConstraintBinding] = []

    public init(vrm: VRM) {
        self.vrm = vrm
        super.init()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setUpHumanoid(nodes: [SCNNode?]) {
        humanoid.setUp(boneNodes: vrm.boneNodes, nodes: nodes)
    }

    func setUpBlendShapes(nodes: [SCNNode?], meshes: [Int: [SCNNode]], loader: VRMSceneLoader) throws {
        expressionClips = [:]
        expressionWeights = [:]
        materialColorClips = [:]
        textureTransformClips = [:]
        morphBindings = [:]
        colorBindings = [:]
        transformBindings = [:]
        defer { indexBindings() }

        switch vrm {
        case .v0(let vrm0):
            // A 0.x group is loaded as the expression it stands for, so the
            // runtime below drives both versions through one set of clips.
            for group in vrm0.blendShapeMaster.blendShapeGroups {
                // A bind names a mesh index, so it drives every node the
                // mesh is drawn under.
                let morphBindings: [BlendShapeBinding] = group.binds?
                    .flatMap { bind in
                        (meshes[bind.mesh] ?? []).flatMap { node in
                            node.allMorphers.map {
                                BlendShapeBinding(mesh: $0, index: bind.index, weight: bind.weight)
                            }
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
                    .flatMap { bind -> [BlendShapeBinding] in
                        guard nodes.indices.contains(bind.node), let node = nodes[bind.node] else {
                            return []
                        }
                        return node.allMorphers.map {
                            BlendShapeBinding(mesh: $0, index: bind.index, weight: bind.weight * 100.0)
                        }
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
                        guard let material = try? loader.material(withMaterialIndex: bind.material) else { return nil }
                        return MaterialColorBinding(material: material,
                                                    type: bind.type,
                                                    targetValue: SIMD4<Float>(bind.targetValue, default: 1.0),
                                                    baseValue: material.currentColor(for: bind.type))
                    } ?? []
                if !colorBindings.isEmpty {
                    materialColorClips[runtimeClip.key] = colorBindings
                }

                let transformBindings: [TextureTransformBinding] = expressionClip.expression.textureTransformBinds?
                    .compactMap { bind in
                        guard let material = try? loader.material(withMaterialIndex: bind.material) else { return nil }
                        let base = material.diffuse.uvTransform
                        return TextureTransformBinding(material: material,
                                                       base: base,
                                                       targetScale: SIMD2<Float>(bind.scale, default: 1.0),
                                                       targetOffset: SIMD2<Float>(bind.offset, default: 0.0))
                    } ?? []
                if !transformBindings.isEmpty {
                    textureTransformClips[runtimeClip.key] = transformBindings
                }
            }
        }
    }

    func setUpFirstPerson(nodes: [SCNNode?], meshes: [Int: [SCNNode]]) {
        switch vrm {
        case .v0(let vrm0):
            firstPersonAnnotations = vrm0.firstPerson.meshAnnotations.flatMap { annotation in
                guard let type = FirstPersonAnnotationType(vrm0Flag: annotation.firstPersonFlag) else {
                    return [FirstPersonAnnotation]()
                }
                return (meshes[annotation.mesh] ?? []).map {
                    FirstPersonAnnotation(node: $0,
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
                return FirstPersonAnnotation(node: node,
                                             type: type,
                                             hidesAutoInFirstPerson: type == .auto && node.isSameOrDescendant(of: head))
            } ?? []
        }
        setFirstPersonRenderMode(.thirdPerson)
    }

    func setUpNodeConstraints(gltfNodes: [GLTF.Node], loader: VRMSceneLoader) throws {
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
    
    func setUpSpringBones(loader: VRMSceneLoader) throws {
        var springBones: [VRMSpringBone] = []
        switch vrm {
        case .v0(let vrm0):
            let secondaryAnimation = vrm0.secondaryAnimation
            let allColliderGroups = try secondaryAnimation.colliderGroups.map {
                try VRMSpringBoneColliderGroup(colliderGroup: $0, loader: loader)
            }
            for boneGroup in secondaryAnimation.boneGroups {
                guard !boneGroup.bones.isEmpty else { continue }
                let rootBones: [SCNNode] = try boneGroup.bones.compactMap { try loader.node(withNodeIndex: $0) }
                let centerNode = try? loader.node(withNodeIndex: boneGroup.center)
                let colliderGroups = boneGroup.colliderGroups.compactMap { index in
                    allColliderGroups.indices.contains(index) ? allColliderGroups[index] : nil
                }
                let springBone = VRMSpringBone(center: centerNode,
                                               rootBones: rootBones,
                                               setting: SpringBoneJointSetting(vrm0BoneGroup: boneGroup),
                                               colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        case .v1(let vrm1):
            guard let springBone = vrm1.springBone else { break }
            for spring in springBone.springs ?? [] {
                let jointNodes = try spring.joints.map { try loader.node(withNodeIndex: $0.node) }
                // A chain of one joint is only a tail, so it swings nothing.
                guard jointNodes.count > 1 else { continue }
                let centerNode = try spring.center.map { try loader.node(withNodeIndex: $0) }
                let colliderGroups = try spring.colliderGroups?.compactMap { groupIndex -> VRMSpringBoneColliderGroup? in
                    guard let groups = springBone.colliderGroups,
                          groups.indices.contains(groupIndex) else {
                        return nil
                    }
                    return try VRMSpringBoneColliderGroup(colliderGroup: groups[groupIndex],
                                                          springBone: springBone,
                                                          loader: loader)
                } ?? []
                let chain = zip(jointNodes, spring.joints).map { node, joint in
                    (node: node, setting: SpringBoneJointSetting(vrm1Joint: joint))
                }
                let springBone = VRMSpringBone(center: centerNode,
                                               chain: chain,
                                               colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        }
        self.springBones = springBones
    }

    public func setExpression(value: CGFloat, for key: ExpressionKey) {
        guard let canonicalKey = canonicalExpressionKey(for: key),
              let clip = expressionClips[canonicalKey] else { return }
        expressionWeights[canonicalKey] = CGFloat(clip.normalizedWeight(Double(value)))
        applyExpressions()
    }

    /// Writes every active expression at once rather than one as it is set:
    /// VRM has expressions overlapping on a morph target, a material colour or
    /// a UV transform add up, and has an active expression suppress the blink,
    /// lookAt and mouth ones, neither of which one expression can answer alone.
    private func applyExpressions() {
        let weights = expressionClips.effectiveWeights(of: expressionWeights.mapValues(Float.init))

        var morphWeights: [MorphBindingKey: Float] = [:]
        var colors: [MaterialColorBindingKey: SIMD4<Float>] = [:]
        var transforms: [ObjectIdentifier: (scale: SIMD2<Float>, offset: SIMD2<Float>)] = [:]
        for (key, weight) in weights {
            for binding in expressionClips[key]?.values ?? [] {
                morphWeights[binding.key, default: 0] += Float(binding.weight / 100.0) * weight
            }
            for binding in materialColorClips[key] ?? [] {
                colors[binding.key, default: binding.baseValue] +=
                    (binding.targetValue - binding.baseValue) * weight
            }
            for binding in textureTransformClips[key] ?? [] {
                let transform = transforms[binding.key] ?? (binding.base.scale, binding.base.offset)
                transforms[binding.key] = (
                    transform.scale + (binding.targetScale - binding.base.scale) * weight,
                    transform.offset + (binding.targetOffset - binding.base.offset) * weight
                )
            }
        }

        for (key, binding) in morphBindings {
            binding.mesh.setWeight(CGFloat(morphWeights[key] ?? 0), forTargetAt: binding.index)
        }
        for (key, binding) in colorBindings {
            binding.material.setColor(colors[key] ?? binding.baseValue, for: binding.type)
        }
        for (key, binding) in transformBindings {
            let transform = transforms[key] ?? (binding.base.scale, binding.base.offset)
            binding.apply(scale: transform.scale, offset: transform.offset)
        }
    }

    /// Collects the bindings of every clip, so that applying the active ones
    /// can put the rest back where they started.
    private func indexBindings() {
        for binding in expressionClips.values.flatMap(\.values) {
            morphBindings[binding.key] = binding
        }
        for binding in materialColorClips.values.flatMap({ $0 }) {
            colorBindings[binding.key] = binding
        }
        for binding in textureTransformClips.values.flatMap({ $0 }) {
            transformBindings[binding.key] = binding
        }
    }

    public func expression(for key: ExpressionKey) -> CGFloat {
        canonicalExpressionKey(for: key).flatMap { expressionWeights[$0] } ?? 0
    }

    public func setFirstPersonRenderMode(_ mode: FirstPersonRenderMode) {
        for annotation in firstPersonAnnotations {
            annotation.node.isHidden = annotation.type.isHidden(in: mode,
                                                                hidesAutoInFirstPerson: annotation.hidesAutoInFirstPerson)
        }
    }

    /// The key a clip is actually stored under. An expression named after a
    /// preset is that preset, which is how VRM 0.x models predating the presets
    /// name theirs.
    private func canonicalExpressionKey(for key: ExpressionKey) -> ExpressionKey? {
        expressionClips.canonicalKey(for: key)
    }

}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension VRMNode {
    /// Advances the node constraints and spring bones to `time`, the timestamp a
    /// renderer hands its per-frame callback.
    public func update(at time: TimeInterval) {
        let seconds = lastUpdateTime.map { max(0, time - $0) } ?? 0
        lastUpdateTime = time
        nodeConstraints.forEach { $0.apply() }
        springBones.forEach({ $0.update(deltaTime: seconds) })
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
private struct NodeConstraintBinding {
    let targetIndex: Int
    let sourceIndex: Int
    let descriptor: VRMNodeConstraintDescriptor
    let target: SCNNode
    let source: SCNNode
    let targetRestRotation: simd_quatf
    let sourceRestRotation: simd_quatf

    init(targetIndex: Int,
         sourceIndex: Int,
         descriptor: VRMNodeConstraintDescriptor,
         target: SCNNode,
         source: SCNNode) {
        self.targetIndex = targetIndex
        self.sourceIndex = sourceIndex
        self.descriptor = descriptor
        self.target = target
        self.source = source
        self.targetRestRotation = target.utx.localRotation
        self.sourceRestRotation = source.utx.localRotation
    }

    func apply() {
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
        guard current != rotation.vector, current != -rotation.vector else { return }
        target.utx.setLocalRotation(rotation)
    }

}

/// Identifies one morph target of one morpher, so that expressions overlapping
/// on a target accumulate into the same weight.
private struct MorphBindingKey: Hashable {
    let morpher: ObjectIdentifier
    let index: Int
}

private extension BlendShapeBinding {
    var key: MorphBindingKey { MorphBindingKey(morpher: ObjectIdentifier(mesh), index: index) }
}

private struct MaterialColorBindingKey: Hashable {
    let material: ObjectIdentifier
    let type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
}

private struct MaterialColorBinding {
    let material: SCNMaterial
    let type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
    let targetValue: SIMD4<Float>
    let baseValue: SIMD4<Float>

    var key: MaterialColorBindingKey {
        MaterialColorBindingKey(material: ObjectIdentifier(material), type: type)
    }
}

private struct TextureTransformBinding {
    let material: SCNMaterial
    /// What the texture was loaded with, which the expression moves away from
    /// and which the rotation of a `KHR_texture_transform` survives in.
    let base: GLTFUVTransform
    let targetScale: SIMD2<Float>
    let targetOffset: SIMD2<Float>

    var key: ObjectIdentifier { ObjectIdentifier(material) }

    func apply(scale: SIMD2<Float>, offset: SIMD2<Float>) {
        material.diffuse.contentsTransform = SCNMatrix4(
            uvTransform: GLTFUVTransform(scale: scale, offset: offset, rotation: base.rotation)
        )
    }
}

private struct FirstPersonAnnotation {
    let node: SCNNode
    let type: FirstPersonAnnotationType
    let hidesAutoInFirstPerson: Bool
}

private extension SCNNode {
    /// Every morpher below this node, each once: the primitives of a mesh
    /// sharing a POSITION accessor share the morpher driving them, and a
    /// weight written to it twice would count twice.
    var allMorphers: [SCNMorpher] {
        var seen: Set<ObjectIdentifier> = []
        var result: [SCNMorpher] = []
        enumerateHierarchy { node, _ in
            if let morpher = node.morpher, seen.insert(ObjectIdentifier(morpher)).inserted {
                result.append(morpher)
            }
        }
        return result
    }

    func isSameOrDescendant(of ancestor: SCNNode?) -> Bool {
        guard let ancestor else { return false }
        var node: SCNNode? = self
        while let current = node {
            if current === ancestor {
                return true
            }
            node = current.parent
        }
        return false
    }
}

private extension SCNMaterial {
    func currentColor(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SIMD4<Float> {
        colorProperty(for: type).simdColor
    }

    func setColor(_ color: SIMD4<Float>, for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) {
        colorProperty(for: type).contents = VRMColor(simd: color)
    }

    private func colorProperty(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType) -> SCNMaterialProperty {
        switch type {
        case .color:
            return diffuse.contents is VRMImage ? multiply : diffuse
        case .emissionColor:
            return emission
        case .shadeColor:
            return multiply
        case .matcapColor:
            return reflective
        case .rimColor:
            return selfIllumination
        case .outlineColor:
            return transparent
        }
    }
}

private extension SCNMaterialProperty {
    var simdColor: SIMD4<Float> {
        guard let color = contents as? VRMColor else {
            return SIMD4<Float>(1, 1, 1, 1)
        }
        return color.simd
    }

    /// The `KHR_texture_transform` the loader wrote, read back so that an
    /// expression moving the scale and the offset leaves the rotation alone.
    var uvTransform: GLTFUVTransform {
        let transform = contentsTransform
        let (m11, m12) = (Float(transform.m11), Float(transform.m12))
        let (m21, m22) = (Float(transform.m21), Float(transform.m22))
        return GLTFUVTransform(scale: SIMD2<Float>(hypot(m11, m12), hypot(m21, m22)),
                               offset: SIMD2<Float>(Float(transform.m41), Float(transform.m42)),
                               rotation: atan2(-m12, m11))
    }
}
