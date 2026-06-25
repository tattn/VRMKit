import SceneKit
import simd
import VRMKit
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
open class VRMNode: SCNNode {
    public let vrm: VRM
    public let humanoid = Humanoid()
    private let timer = Timer()
    private var springBones: [VRMSpringBone] = []

    var blendShapeClips: [BlendShapeKey: BlendShapeClip] = [:]
    private var materialColorClips: [BlendShapeKey: [MaterialColorBinding]] = [:]
    private var textureTransformClips: [BlendShapeKey: [TextureTransformBinding]] = [:]
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
        switch vrm {
        case .v0:
            humanoid.setUp(humanoid: vrm.humanoid, nodes: nodes)
        case .v1(let vrm1):
            humanoid.setUp(humanoid: vrm1.humanoid, nodes: nodes)
        }
    }

    func setUpBlendShapes(nodes: [SCNNode?], meshes: [SCNNode?], loader: VRMSceneLoader) throws {
        blendShapeClips = [:]
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
                let clip = BlendShapeClip(name: expressionClip.name,
                                          preset: expressionClip.preset,
                                          values: morphBindings,
                                          isBinary: expressionClip.expression.isBinary ?? false)
                blendShapeClips[clip.key] = clip

                let colorBindings: [MaterialColorBinding] = try expressionClip.expression.materialColorBinds?
                    .compactMap { bind in
                        guard bind.targetValue.count >= 3 else { return nil }
                        let material = try loader.material(withMaterialIndex: bind.material)
                        return MaterialColorBinding(material: material,
                                                    type: bind.type,
                                                    targetValue: SIMD4<Float>(bind.targetValue, defaultAlpha: 1.0),
                                                    baseValue: material.currentColor(for: bind.type))
                    } ?? []
                if !colorBindings.isEmpty {
                    materialColorClips[clip.key] = colorBindings
                }

                let transformBindings: [TextureTransformBinding] = try expressionClip.expression.textureTransformBinds?
                    .compactMap { bind in
                        let material = try loader.material(withMaterialIndex: bind.material)
                        let base = material.diffuse.scaleOffset
                        return TextureTransformBinding(material: material,
                                                       baseScale: base.scale,
                                                       baseOffset: base.offset,
                                                       targetScale: SIMD2<Float>(bind.scale, defaultValue: 1.0),
                                                       targetOffset: SIMD2<Float>(bind.offset, defaultValue: 0.0))
                    } ?? []
                if !transformBindings.isEmpty {
                    textureTransformClips[clip.key] = transformBindings
                }
            }
        }
    }

    func setUpFirstPerson(nodes: [SCNNode?], meshes: [SCNNode?]) {
        switch vrm {
        case .v0:
            firstPersonAnnotations = vrm.firstPerson.meshAnnotations.compactMap { annotation in
                guard meshes.indices.contains(annotation.mesh),
                      let mesh = meshes[annotation.mesh],
                      let type = FirstPersonAnnotationType(vrm0Flag: annotation.firstPersonFlag) else {
                    return nil
                }
                return FirstPersonAnnotation(node: mesh,
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
        nodeConstraints = try NodeConstraintBinding.ordered(bindings)
    }
    
    func setUpSpringBones(loader: VRMSceneLoader) throws {
        var springBones: [VRMSpringBone] = []
        switch vrm {
        case .v0:
            let secondaryAnimation = vrm.secondaryAnimation
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
                                               comment: boneGroup.comment,
                                               stiffnessForce: Float(boneGroup.stiffiness),
                                               gravityPower: Float(boneGroup.gravityPower),
                                               gravityDir: boneGroup.gravityDir.simd,
                                               dragForce: Float(boneGroup.dragForce),
                                               hitRadius: Float(boneGroup.hitRadius),
                                               colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        case .v1(let vrm1):
            guard let springBone = vrm1.springBone else { break }
            for spring in springBone.springs ?? [] {
                let jointNodes = try spring.joints.compactMap { try loader.node(withNodeIndex: $0.node) }
                guard !jointNodes.isEmpty else { continue }
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
                let settings = Dictionary(uniqueKeysWithValues: zip(jointNodes, spring.joints).map { node, joint in
                    (ObjectIdentifier(node), VRMSpringBone.JointSetting(joint: joint))
                })
                let springBone = VRMSpringBone(center: centerNode,
                                               rootBones: [jointNodes[0]],
                                               comment: spring.name,
                                               jointChain: jointNodes,
                                               jointSettings: settings,
                                               colliderGroups: colliderGroups)
                springBones.append(springBone)
            }
        }
        self.springBones = springBones
    }

    /// Set blend shapes to avatar
    ///
    /// - Parameters:
    ///   - value: a weight of the blend shape (0.0 <= value <= 1.0)
    ///   - key: a key of the blend shape
    public func setBlendShape(value: CGFloat, for key: BlendShapeKey) {
        guard let clip = blendShapeClip(for: key) else { return }
        let value: CGFloat = clip.isBinary ? round(value) : value
        for binding in clip.values {
            let weight = CGFloat(binding.weight / 100.0)
            for morpher in binding.mesh.allMorphers {
                morpher.setWeight(weight * value, forTargetAt: binding.index)
            }
        }
        for binding in materialColorClip(for: key) {
            binding.apply(value: Float(value))
        }
        for binding in textureTransformClip(for: key) {
            binding.apply(value: Float(value))
        }
    }

    /// Get a weight of the blend shape
    ///
    /// - Parameter key: a key of the blend shape
    /// - Returns: a weight of the blend shape
    public func blendShape(for key: BlendShapeKey) -> CGFloat {
        guard let clip = blendShapeClip(for: key),
            let binding = clip.values.first,
            let morpher = binding.mesh.allMorphers.first else { return 0 }
        return morpher.weight(forTargetAt: binding.index)
    }

    public func setFirstPersonRenderMode(_ mode: FirstPersonRenderMode) {
        for annotation in firstPersonAnnotations {
            annotation.node.isHidden = annotation.type.isHidden(in: mode,
                                                                hidesAutoInFirstPerson: annotation.hidesAutoInFirstPerson)
        }
    }

    private func blendShapeClip(for key: BlendShapeKey) -> BlendShapeClip? {
        if let clip = blendShapeClips[key] { return clip }
        return key.aliases.lazy.compactMap { self.blendShapeClips[$0] }.first
    }

    private func materialColorClip(for key: BlendShapeKey) -> [MaterialColorBinding] {
        if let clip = materialColorClips[key] { return clip }
        return key.aliases.lazy.compactMap { self.materialColorClips[$0] }.first ?? []
    }

    private func textureTransformClip(for key: BlendShapeKey) -> [TextureTransformBinding] {
        if let clip = textureTransformClips[key] { return clip }
        return key.aliases.lazy.compactMap { self.textureTransformClips[$0] }.first ?? []
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension VRMNode: RenderUpdatable {
    public func update(at time: TimeInterval) {
        let seconds = timer.deltaTime(updateAtTime: time)
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

private enum FirstPersonAnnotationType {
    case auto
    case both
    case thirdPersonOnly
    case firstPersonOnly

    init(vrm1Type: VRM1.FirstPerson.FirstPersonType) {
        switch vrm1Type {
        case .auto: self = .auto
        case .both: self = .both
        case .thirdPersonOnly: self = .thirdPersonOnly
        case .firstPersonOnly: self = .firstPersonOnly
        }
    }

    init?(vrm0Flag: String) {
        switch vrm0Flag.replacingOccurrences(of: "_", with: "").lowercased() {
        case "auto":
            self = .auto
        case "both":
            self = .both
        case "thirdpersononly":
            self = .thirdPersonOnly
        case "firstpersononly":
            self = .firstPersonOnly
        default:
            return nil
        }
    }

    func isHidden(in mode: FirstPersonRenderMode, hidesAutoInFirstPerson: Bool) -> Bool {
        switch (self, mode) {
        case (.auto, .firstPerson):
            return hidesAutoInFirstPerson
        case (.firstPersonOnly, .thirdPerson),
             (.thirdPersonOnly, .firstPerson):
            return true
        default:
            return false
        }
    }
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

private extension VRMColor {
    convenience init(simd color: SIMD4<Float>) {
        self.init(red: CGFloat(color.x),
                  green: CGFloat(color.y),
                  blue: CGFloat(color.z),
                  alpha: CGFloat(color.w))
    }

    var simd: SIMD4<Float> {
        #if os(macOS)
        let color = usingColorSpace(.deviceRGB) ?? self
        return SIMD4<Float>(Float(color.redComponent),
                            Float(color.greenComponent),
                            Float(color.blueComponent),
                            Float(color.alphaComponent))
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
        #endif
    }
}

private extension SIMD4 where Scalar == Float {
    init(_ values: [Double], defaultAlpha: Float) {
        self.init(Float(values[safe: 0] ?? 0),
                  Float(values[safe: 1] ?? 0),
                  Float(values[safe: 2] ?? 0),
                  Float(values[safe: 3] ?? Double(defaultAlpha)))
    }
}

private extension SIMD2 where Scalar == Float {
    init(_ values: [Double]?, defaultValue: Float) {
        self.init(Float(values?[safe: 0] ?? Double(defaultValue)),
                  Float(values?[safe: 1] ?? Double(defaultValue)))
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
