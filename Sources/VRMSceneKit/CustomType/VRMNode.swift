import OSLog
import SceneKit
import simd
import VRMKit
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
open class VRMNode: SCNNode {
    private static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "VRMSceneKit")

    public let vrm: VRM
    public let humanoid = Humanoid()
    private var lastUpdateTime: TimeInterval?
    private var springBones = SpringBoneRig<SCNNode>()

    var expressionClips: [ExpressionKey: ExpressionClip] = [:]
    private var expressionWeights: [ExpressionKey: CGFloat] = [:]
    private var materialColorClips: [ExpressionKey: [MaterialColorBinding]] = [:]
    private var textureTransformClips: [ExpressionKey: [TextureTransformBinding]] = [:]
    // Every binding any expression holds, so a target no active expression
    // touches goes back to what it was.
    private var morphBindings: [MorphBindingKey: BlendShapeBinding] = [:]
    private var colorBindings: [MaterialColorBindingKey: MaterialColorBinding] = [:]
    private var transformBindings: [ObjectIdentifier: TextureTransformBinding] = [:]
    private var firstPersonAnnotations: [FirstPersonAnnotation] = []
    private var firstPersonPrimitives: [ObjectIdentifier: FirstPersonPrimitive] = [:]
    private var nodeConstraints = NodeConstraintRig<SCNNode>()

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

    func setUpBlendShapes(nodes: [SCNNode?],
                          meshes: [Int: [SceneData.SceneMesh]],
                          loader: VRMSceneLoader) throws {
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
                        (meshes[bind.mesh] ?? []).flatMap { sceneMesh in
                            sceneMesh.node.allMorphers.map {
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
                        // A malformed bind only invalidates that bind, never the
                        // whole model load, so it is reported rather than thrown.
                        guard let material = try? loader.material(withMaterialIndex: bind.material) else {
                            Self.logger.warning("""
                            Skipping invalid MaterialColorBind. \
                            expression=\(expressionClip.name, privacy: .public) \
                            materialIndex=\(bind.material)
                            """)
                            return nil
                        }
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
                        // As above, a malformed bind only invalidates itself.
                        guard let material = try? loader.material(withMaterialIndex: bind.material) else {
                            Self.logger.warning("""
                            Skipping invalid TextureTransformBind. \
                            expression=\(expressionClip.name, privacy: .public) \
                            materialIndex=\(bind.material)
                            """)
                            return nil
                        }
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

    /// What each camera draws of each mesh. The `auto` cut is made as the meshes
    /// are built, so this only pairs it with the node drawing it.
    func setUpFirstPerson(plan: VRMFirstPersonPlan,
                          nodes: [SCNNode?],
                          meshes: [Int: [SceneData.SceneMesh]],
                          primitives: [ObjectIdentifier: FirstPersonPrimitive]) {
        firstPersonPrimitives = primitives
        let head = plan.headNode.flatMap { nodes[safe: $0] ?? nil }
        firstPersonAnnotations = meshes.sorted { $0.key < $1.key }.flatMap { meshIndex, sceneMeshes in
            sceneMeshes.map { sceneMesh in
                FirstPersonAnnotation(node: sceneMesh.node,
                                      type: plan.annotation(ofNodeAt: sceneMesh.nodeIndex, meshIndex: meshIndex),
                                      // An unskinned mesh cannot be cut, so the head takes it whole.
                                      hidesAutoInFirstPerson: sceneMesh.node.isSameOrDescendant(of: head))
            }
        }
        setFirstPersonRenderMode(.thirdPerson)
    }

    func setUpNodeConstraints(gltfNodes: [GLTF.Node],
                              hierarchy: GLTFNodeHierarchy,
                              loader: VRMSceneLoader) throws {
        nodeConstraints = try NodeConstraintRig.make(vrm: vrm, gltfNodes: gltfNodes, hierarchy: hierarchy) {
            try loader.node(withNodeIndex: $0)
        }
    }

    func setUpSpringBones(loader: VRMSceneLoader) throws {
        springBones = try SpringBoneRig.make(vrm: vrm) { try loader.node(withNodeIndex: $0) }
    }

    public func setExpression(value: CGFloat, for key: ExpressionKey) {
        guard let canonicalKey = canonicalExpressionKey(for: key),
              let clip = expressionClips[canonicalKey] else { return }
        expressionWeights[canonicalKey] = CGFloat(clip.normalizedWeight(Double(value)))
        applyExpressions()
    }

    /// Writes every active expression at once rather than one as it is set: VRM
    /// has overlapping expressions add up, and has an active one suppress the
    /// blink, lookAt and mouth expressions.
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
            // An `auto` mesh is cut rather than hidden, so the body below it stays.
            if annotation.type == .auto, applyFirstPersonCut(mode, to: annotation.node) { continue }
            annotation.node.isHidden = annotation.type.isHidden(in: mode,
                                                                hidesAutoInFirstPerson: annotation.hidesAutoInFirstPerson)
        }
    }

    /// Draws the primitives under `node` with the triangles `mode` asks for, and
    /// says whether any of them was cut.
    private func applyFirstPersonCut(_ mode: FirstPersonRenderMode, to node: SCNNode) -> Bool {
        var cut = false
        node.enumerateHierarchy { primitiveNode, _ in
            guard let primitive = firstPersonPrimitives[ObjectIdentifier(primitiveNode)] else { return }
            cut = true
            // A primitive with nothing standing in for it just goes.
            primitive.thirdPerson.isHidden = mode == .firstPerson
            primitive.firstPerson?.isHidden = mode == .thirdPerson
        }
        return cut
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
        _ = nodeConstraints.apply()
        springBones.update(deltaTime: seconds)
    }
}


/// Identifies one morph target of one morpher, so that expressions overlapping
/// on a target accumulate into the same weight.
private struct MorphBindingKey: Hashable {
    let morpher: ObjectIdentifier
    let index: Int
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
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

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
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
    /// Every morpher below this node, each once: the primitives of a mesh sharing
    /// a POSITION accessor share the morpher driving them.
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
