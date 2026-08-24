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

        switch vrm {
        case .v0(let vrm0):
            // A 0.x group is loaded as the expression it stands for, so the
            // runtime below drives both versions through one set of clips.
            for group in vrm0.blendShapeMaster.blendShapeGroups {
                // A bind names a mesh index, so it drives every node the
                // mesh is drawn under.
                let morphBindings: [BlendShapeBinding] = group.binds?
                    .flatMap { bind in
                        (meshes[bind.mesh] ?? []).map {
                            BlendShapeBinding(mesh: $0.allMorphers, index: bind.index, weight: bind.weight)
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
                        return BlendShapeBinding(mesh: node.allMorphers,
                                                 index: bind.index,
                                                 weight: bind.weight * 100.0)
                    } ?? []
                let runtimeClip = ExpressionClip(name: expressionClip.name,
                                                 preset: expressionClip.preset,
                                                 values: morphBindings,
                                                 isBinary: expressionClip.expression.isBinary ?? false)
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
                        let base = material.diffuse.scaleOffset
                        return TextureTransformBinding(material: material,
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
        let value = CGFloat(clip.normalizedWeight(Double(value)))
        expressionWeights[canonicalKey] = value
        for binding in clip.values {
            let weight = CGFloat(binding.weight / 100.0)
            for morpher in binding.mesh {
                morpher.setWeight(weight * value, forTargetAt: binding.index)
            }
        }
        for binding in materialColorClips[canonicalKey] ?? [] {
            binding.apply(value: Float(value))
        }
        for binding in textureTransformClips[canonicalKey] ?? [] {
            binding.apply(value: Float(value))
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

private struct MaterialColorBinding {
    let material: SCNMaterial
    let type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
    let targetValue: SIMD4<Float>
    let baseValue: SIMD4<Float>

    func apply(value: Float) {
        material.setColor(baseValue + (targetValue - baseValue) * value, for: type)
    }
}

private struct TextureTransformBinding {
    let material: SCNMaterial
    let baseScale: SIMD2<Float>
    let baseOffset: SIMD2<Float>
    let targetScale: SIMD2<Float>
    let targetOffset: SIMD2<Float>

    func apply(value: Float) {
        let scale = baseScale + (targetScale - baseScale) * value
        let offset = baseOffset + (targetOffset - baseOffset) * value
        material.diffuse.contentsTransform = SCNMatrix4(scale: scale, offset: offset)
    }
}

private struct FirstPersonAnnotation {
    let node: SCNNode
    let type: FirstPersonAnnotationType
    let hidesAutoInFirstPerson: Bool
}

private extension SCNNode {
    var allMorphers: [SCNMorpher] {
        var result: [SCNMorpher] = []
        enumerateHierarchy { node, _ in
            if let morpher = node.morpher {
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

    var scaleOffset: (scale: SIMD2<Float>, offset: SIMD2<Float>) {
        let transform = contentsTransform
        return (SIMD2<Float>(Float(transform.m11), Float(transform.m22)),
                SIMD2<Float>(Float(transform.m41), Float(transform.m42)))
    }
}

private extension SCNMatrix4 {
    init(scale: SIMD2<Float>, offset: SIMD2<Float>) {
        self = SCNMatrix4Identity
        m11 = SCNFloat(scale.x)
        m22 = SCNFloat(scale.y)
        m41 = SCNFloat(offset.x)
        m42 = SCNFloat(offset.y)
    }
}
