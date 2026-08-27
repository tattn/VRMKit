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

    /// The expression accumulation and dirty tracking VRM defines, shared with the
    /// RealityKit renderer; this node only writes the results out.
    private let expressions = ExpressionRuntime<SCNMorpher, SCNMaterial>()
    var expressionClips: [ExpressionKey: ExpressionClip] { expressions.clips }
    private var firstPersonAnnotations: [FirstPersonAnnotation] = []

    private lazy var expressionApplier = ExpressionApplier<SCNMorpher, SCNMaterial>(
        setMorphWeight: { weight, targetIndex, morpher in
            morpher.setWeight(CGFloat(weight), forTargetAt: targetIndex)
        },
        setMaterialColor: { color, type, material in
            material.setColor(color, for: type)
        },
        setTextureTransform: { scale, offset, rotation, material in
            material.diffuse.contentsTransform = SCNMatrix4(
                uvTransform: GLTFUVTransform(scale: scale, offset: offset, rotation: rotation)
            )
        }
    )
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
                          loader: VRMSceneLoader) {
        expressions.setUp(
            plan: VRMExpressionPlan(vrm: vrm),
            morphBindings: { bind in
                // A mesh or a node may be drawn by several morphers.
                let bound: [SCNNode]
                switch bind.target {
                case .mesh(let index):
                    bound = (meshes[index] ?? []).map(\.node)
                case .node(let index):
                    guard let node = nodes[safe: index] ?? nil else { return [] }
                    bound = [node]
                }
                return bound.flatMap(\.allMorphers).map {
                    BlendShapeBinding(mesh: $0, index: bind.index, weight: bind.weight)
                }
            },
            materialColorBinding: { expression, bind in
                // A malformed bind only invalidates itself, never the whole load.
                guard let material = try? loader.material(withMaterialIndex: bind.material) else {
                    Self.logger.warning("""
                    Skipping invalid MaterialColorBind. \
                    expression=\(expression, privacy: .public) materialIndex=\(bind.material)
                    """)
                    return nil
                }
                return ExpressionMaterialColorBinding(material: material,
                                                      type: bind.type,
                                                      targetValue: bind.targetValue,
                                                      baseValue: material.currentColor(for: bind.type))
            },
            textureTransformBinding: { expression, bind in
                // As above, a malformed bind only invalidates itself.
                guard let material = try? loader.material(withMaterialIndex: bind.material) else {
                    Self.logger.warning("""
                    Skipping invalid TextureTransformBind. \
                    expression=\(expression, privacy: .public) materialIndex=\(bind.material)
                    """)
                    return nil
                }
                let base = material.diffuse.uvTransform
                return ExpressionTextureTransformBinding(material: material,
                                                         baseScale: base.scale,
                                                         baseOffset: base.offset,
                                                         baseRotation: base.rotation,
                                                         targetScale: bind.scale,
                                                         targetOffset: bind.offset)
            }
        )
    }

    /// What each camera draws of each mesh. The `auto` cut is made as the meshes are
    /// built, so this only pairs it with the node drawing it.
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
        setExpressions([key: value])
    }

    /// Sets several expression weights and re-applies the result once. Applying
    /// re-accumulates every active clip, so prefer this over repeated
    /// ``setExpression(value:for:)`` calls in one frame.
    public func setExpressions(_ weights: [ExpressionKey: CGFloat]) {
        guard expressions.storeWeights(weights.mapValues(Double.init)) else { return }
        expressions.apply(with: expressionApplier)
    }

    public func expression(for key: ExpressionKey) -> CGFloat {
        CGFloat(expressions.weight(for: key))
    }

    /// The expressions the model offers, for enumerating what may be set.
    public var availableExpressions: [ExpressionKey] {
        expressions.availableExpressions
    }

    public func setFirstPersonRenderMode(_ mode: FirstPersonRenderMode) {
        for annotation in firstPersonAnnotations {
            // An `auto` mesh is cut rather than hidden, so the body below it stays.
            if annotation.type == .auto, applyFirstPersonCut(mode, to: annotation.node) { continue }
            annotation.node.isHidden = annotation.type.isHidden(in: mode,
                                                                hidesAutoInFirstPerson: annotation.hidesAutoInFirstPerson)
        }
    }

    /// Draws the primitives under `node` with the triangles `mode` asks for, and reports
    /// whether any of them was cut.
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

}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension VRMNode {
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

    /// Advances the node constraints and spring bones to `time`, the timestamp a renderer
    /// hands its per-frame callback.
    public func update(at time: TimeInterval) {
        let seconds = lastUpdateTime.map { max(0, time - $0) } ?? 0
        lastUpdateTime = time
        _ = nodeConstraints.apply()
        springBones.update(deltaTime: seconds)
    }
}


private struct FirstPersonAnnotation {
    let node: SCNNode
    let type: FirstPersonAnnotationType
    let hidesAutoInFirstPerson: Bool
}

private extension SCNNode {
    /// Every morpher below this node, each once: the primitives of a mesh sharing a
    /// POSITION accessor share the morpher driving them.
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

    /// The `KHR_texture_transform` the loader wrote, read back so an expression moving
    /// the scale and offset leaves the rotation alone.
    var uvTransform: GLTFUVTransform {
        let transform = contentsTransform
        let (m11, m12) = (Float(transform.m11), Float(transform.m12))
        let (m21, m22) = (Float(transform.m21), Float(transform.m22))
        return GLTFUVTransform(scale: SIMD2<Float>(hypot(m11, m12), hypot(m21, m22)),
                               offset: SIMD2<Float>(Float(transform.m41), Float(transform.m42)),
                               rotation: atan2(-m12, m11))
    }
}
