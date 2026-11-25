#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat
import VRMKit

/// Where in ``VRMInstance/update(deltaTime:)`` a handler set with
/// ``VRMInstance/setUpdateHandler(_:at:)`` runs.
public enum VRMUpdateStage: Sendable {
    /// After the animations pose the model, before the node constraints, the gaze and the
    /// spring bones read the pose.
    case afterAnimation
    /// After the spring bones, before the output is put together.
    case beforeSkinning
}

/// One VRM model built from an asset, moving on its own: on top of a glTF instance, its
/// expressions, node constraints, gaze, spring bones and first-person view. It holds no
/// renderer type and is bound to no actor.
public final class VRMInstance: GLTFInstance {
    public let vrm: VRM

    /// What an expression's material bind starts from: the color or the UV transform the
    /// material draws with before any expression moves it.
    package struct MaterialBase {
        package let color: (Int, ExpressionMaterialColorType) -> SIMD4<Float>?
        package let uvTransform: (Int) -> (scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float)?

        package init(color: @escaping (Int, ExpressionMaterialColorType) -> SIMD4<Float>?,
                     uvTransform: @escaping (Int) -> (scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float)?) {
            self.color = color
            self.uvTransform = uvTransform
        }
    }

    private let humanoidNodes: [HumanoidBone: Int]
    private let expressions = ExpressionRuntime()
    private var springBones = SpringBoneRig<GLTFPoseNode>()
    private var nodeConstraints = NodeConstraintRig<GLTFPoseNode>()
    private var lookAt = LookAtRig<GLTFPoseNode>()
    private let firstPerson: VRMFirstPersonPlan
    /// The pose the document describes before any animation runs, which retargeting reads.
    private var restPose: GLTFRestPose?
    private var updateHandlers: [VRMUpdateStage: (TimeInterval) -> Void] = [:]

    /// What expressions set on one material, and the stamp of its last change.
    private struct MaterialEntry {
        var values = GLTFFrameOutput.MaterialValues()
        var changed: UInt64 = 0

        mutating func change(at stamp: UInt64, _ body: (inout GLTFFrameOutput.MaterialValues) -> Void) {
            body(&values)
            changed = stamp
        }
    }

    private var materialEntries: [Int: MaterialEntry] = [:]
    private var lastMaterialChange: UInt64 = 0
    private var visibilityChange: UInt64 = 1

    private lazy var expressionApplier = ExpressionApplier(
        setMorphWeight: { [unowned self] weight, target, node in
            setMorphWeight(weight, forTarget: target, ofNode: node)
        },
        setMaterialColor: { [unowned self] color, type, material in
            changeMaterial(material) { $0.colors[type] = color }
        },
        setTextureTransform: { [unowned self] scale, offset, rotation, material in
            changeMaterial(material) { $0.uvTransform = (scale, offset, rotation) }
        }
    )

    private func changeMaterial(_ material: Int, _ body: (inout GLTFFrameOutput.MaterialValues) -> Void) {
        materialEntries[material, default: MaterialEntry()].change(at: changeStamp, body)
        lastMaterialChange = changeStamp
    }

    /// - Throws: when the asset was not read from a VRM, or the model states a spring,
    ///   constraint or gaze its nodes cannot hold.
    public convenience init(asset: GLTFAsset) throws {
        try self.init(asset: asset, pose: asset.makePose(), materialBase: Self.materialBase(of: asset))
    }

    package init(asset: GLTFAsset, pose: GLTFPose, materialBase: MaterialBase) throws {
        guard let vrm = asset.vrm else {
            throw VRMError._dataInconsistent("a VRM instance needs an asset read from a VRM")
        }
        self.vrm = vrm
        humanoidNodes = vrm.boneNodes
        firstPerson = VRMFirstPersonPlan(vrm: vrm, gltf: asset.document.gltf, hierarchy: asset.hierarchy)
        super.init(asset: asset, pose: pose)

        let pose = pose
        let node: (Int) throws -> GLTFPoseNode = { index in
            guard pose.nodes.indices.contains(index) else {
                throw VRMError._dataInconsistent("node \(index) is not part of this model's pose")
            }
            return pose.nodes[index]
        }
        nodeConstraints = try NodeConstraintRig.make(vrm: vrm,
                                                     gltfNodes: asset.document.gltf.nodes,
                                                     hierarchy: asset.hierarchy,
                                                     node: node)
        springBones = try SpringBoneRig.make(vrm: vrm, node: node)
        lookAt = try LookAtRig.make(vrm: vrm, node: node)
        setUpExpressions(materialBase: materialBase)
    }

    private func setUpExpressions(materialBase: MaterialBase) {
        let morphNodes = asset.meshIndicesByNode.keys.filter { morphWeights(ofNode: $0) != nil }
        expressions.setUp(
            clips: asset.expressionClips,
            morphNodes: { target in
                switch target {
                case .mesh(let index): morphNodes.filter { asset.nodes[$0].mesh == index }
                case .node(let index): morphNodes.contains(index) ? [index] : []
                }
            },
            // A malformed bind only invalidates itself.
            baseColor: materialBase.color,
            baseUVTransform: materialBase.uvTransform
        )
    }

    /// The colors and UV transforms the asset's materials are read with.
    private static func materialBase(of asset: GLTFAsset) -> MaterialBase {
        MaterialBase(
            color: { index, type in
                guard let material = asset.materials[safe: index] else { return nil }
                if case .mtoon(let mtoon) = material.shading {
                    switch type {
                    case .color: return mtoon.baseColorFactor
                    case .emissionColor: return SIMD4(mtoon.emissiveFactor, 1)
                    case .shadeColor: return mtoon.shadeColorFactor
                    case .matcapColor: return SIMD4(mtoon.matcapFactor, 1)
                    case .rimColor: return mtoon.parametricRimColorFactor
                    case .outlineColor: return mtoon.outlineColorFactor
                    }
                }
                switch type {
                case .color:
                    return material.material.pbrMetallicRoughness?.baseColorFactor ?? SIMD4(repeating: 1)
                case .emissionColor:
                    if case .physicallyBased = material.shading { return SIMD4(material.material.emissiveFactor, 1) }
                    return SIMD4(repeating: 1)
                case .shadeColor, .matcapColor, .rimColor, .outlineColor:
                    return SIMD4(repeating: 1)
                }
            },
            uvTransform: { index in
                asset.materials[safe: index].map { ($0.uvTransform.scale, $0.uvTransform.offset, $0.uvTransform.rotation) }
            }
        )
    }

    // MARK: - Bones

    /// The node of a humanoid bone, nil for a bone the model does not have.
    public func node(for bone: HumanoidBone) -> Int? {
        humanoidNodes[bone]
    }

    // MARK: - A frame

    /// Advances the model by one frame: its animations, the code set with
    /// ``setUpdateHandler(_:at:)``, node constraints, the gaze and spring bones, in that order.
    /// What moved is read through a reader.
    public override func update(deltaTime: TimeInterval) {
        let deltaTime = max(0, deltaTime)
        change {
            animationPlayer.advance(deltaTime: deltaTime)
            updateHandlers[.afterAnimation]?(deltaTime)
            followPose(deltaTime: deltaTime)
            updateHandlers[.beforeSkinning]?(deltaTime)
        }
    }

    /// Advances only what follows the pose: node constraints, the gaze and spring bones. No
    /// animation advances and no update handler runs, so a pose held still keeps its shape
    /// while its spring bones settle.
    public func updateSecondaryMotion(deltaTime: TimeInterval) {
        change { followPose(deltaTime: max(0, deltaTime)) }
    }

    private func followPose(deltaTime: TimeInterval) {
        nodeConstraints.apply()
        // After the constraints, which may have posed the head the gaze is measured from,
        // and before the springs, which nothing about the eyes feeds into.
        applyLookAt()
        _ = springBones.update(deltaTime: deltaTime)
    }

    /// Runs `handler` at `stage` of every ``update(deltaTime:)``, with the frame's time, in
    /// place of the one set there before; nil removes it.
    public func setUpdateHandler(_ handler: ((TimeInterval) -> Void)?, at stage: VRMUpdateStage) {
        updateHandlers[stage] = handler
    }

    override func didAnimate(_ output: GLTFAnimationOutput) {
        super.didAnimate(output)
        if !output.expressionWeights.isEmpty, expressions.storeWeights(output.expressionWeights) {
            expressions.apply(with: expressionApplier)
        }
        if let gaze = output.gaze {
            lookAtTarget = .rotation(gaze)
        }
    }

    override func addChanges(since stamp: UInt64, to output: inout GLTFFrameOutput) {
        if lastMaterialChange > stamp {
            for (material, entry) in materialEntries where entry.changed > stamp {
                output.materialValues[material] = entry.values
            }
        }
        if visibilityChange > stamp {
            output.visibility = visibility()
        }
    }

    // MARK: - Animations

    /// Starts playing a VRM animation (`.vrma`), retargeted onto this model's humanoid bones
    /// and expressions, and returns its controller.
    @discardableResult
    public func playAnimation(_ animation: VRMAnimation,
                              animationIndex: Int = 0,
                              loops: Bool = false,
                              speed: Float = 1) throws -> GLTFAnimationPlaybackController {
        let restPose = try self.restPose ?? GLTFRestPose(nodes: asset.document.gltf.nodes)
        self.restPose = restPose
        let model = VRMAnimationRuntime.Model(facesNegativeZ: vrm.forwardDirection.z < 0,
                                              humanoidNodes: humanoidNodes,
                                              restPose: restPose)
        // Retargeting is specific to this (animation, model) pair, so it is built per
        // playback and owned by its controller.
        let runtime = try VRMAnimationRuntime(animation: animation, animationIndex: animationIndex, model: model)
        return change {
            animationPlayer.start(GLTFAnimation(index: animationIndex, name: runtime.name, duration: runtime.duration),
                                  runtime: runtime,
                                  ownsRuntime: true,
                                  loops: loops,
                                  speed: speed)
        }
    }

    // MARK: - Expressions

    /// The expressions the model offers, each paired with the name it states them under.
    public var availableExpressions: [ExpressionInfo] {
        expressions.availableExpressions
    }

    /// Sets several expression weights and re-applies the result once.
    public func setExpressions(_ weights: [ExpressionKey: Float]) {
        guard expressions.storeWeights(weights) else { return }
        change { expressions.apply(with: expressionApplier) }
    }

    /// The handle to set `key` with in ``ExpressionWeights``, or nil when the model offers no
    /// such expression.
    public func expressionHandle(for key: ExpressionKey) -> ExpressionHandle? {
        expressions.handle(for: key)
    }

    /// Expression weights for this model, none set yet, to set by handle every frame.
    public func makeExpressionWeights() -> ExpressionWeights {
        ExpressionWeights(count: expressions.expressionCount)
    }

    /// Sets the weights `weights` sets and re-applies the result once.
    public func setExpressions(_ weights: ExpressionWeights) {
        guard expressions.storeWeights(weights) else { return }
        change { expressions.apply(with: expressionApplier) }
    }

    public func expression(for key: ExpressionKey) -> Float {
        expressions.weight(for: key)
    }

    // MARK: - Gaze

    /// What the eyes follow, nil to leave them at rest. A world-space position is measured
    /// against ``GLTFPose/rootMatrix``, and kept on as either it or the model moves. A model
    /// stating no look-at keeps its eyes still whatever this is set to.
    public var lookAtTarget: LookAtTarget? {
        get { lookAt.target }
        set {
            lookAt.target = newValue
            change { applyLookAt() }
        }
    }

    private func applyLookAt() {
        switch lookAt.apply() {
        case .unchanged, .posedBones:
            break
        case .weights(let weights):
            guard expressions.storeWeights(weights) else { return }
            expressions.apply(with: expressionApplier)
        }
    }

    // MARK: - Spring bones

    /// How the spring bones swing: the wind pushing them, if any.
    public var springBoneConfiguration: SpringBoneConfiguration {
        get { springBones.configuration }
        set { springBones.configuration = newValue }
    }

    /// Forgets the motion the spring bones carry between frames, so the next update starts
    /// them at rest.
    public func resetSpringBones() {
        springBones.reset()
    }

    /// Has the node `center` carry `share` of its motion into the tail of the spring-bone
    /// joint on the node `joint`, in place of the spring's center for that joint.
    public func setSpringBoneCenter(_ center: Int, share: Float, forJoint joint: Int) throws {
        guard pose.nodes.indices.contains(center), pose.nodes.indices.contains(joint) else {
            throw VRMError._dataInconsistent("a spring-bone center and its joint have to be nodes of this model")
        }
        try springBones.setCenter(pose.nodes[center], share: share, forJoint: pose.nodes[joint])
    }

    /// The local rotation the spring-bone joint on `node` rests at, nil for a node no spring swings.
    public func springBoneRestRotation(ofJoint node: Int) -> simd_quatf? {
        guard pose.nodes.indices.contains(node) else { return nil }
        return springBones.restRotation(ofJoint: pose.nodes[node])
    }

    /// Moves where the spring-bone joint on `node` rests to the local `rotation`, where the model
    /// states it: the joint and what swings below it turn along at once, and swing around the new rest. A rotation set on
    /// the node itself is overwritten by the spring.
    public func setSpringBoneRestRotation(_ rotation: simd_quatf, ofJoint node: Int) throws {
        guard pose.nodes.indices.contains(node), springBones.restRotation(ofJoint: pose.nodes[node]) != nil else {
            throw VRMError._invalidArgument("the node is not a joint any spring swings")
        }
        springBones.setRestRotation(rotation, ofJoint: pose.nodes[node])
    }

    /// Turns the spring bones at and below `node` by `turn`, in its parent's space, around `node`: for
    /// a node posed on purpose that spring bones hang off, so that its turn swings none of them.
    public func turnSpringBones(under node: Int, by turn: simd_quatf) {
        guard pose.nodes.indices.contains(node) else { return }
        springBones.turnTails(under: pose.nodes[node], by: turn)
    }

    // MARK: - First person

    /// Which camera the model draws for, as VRM's first-person settings ask. An `auto` mesh
    /// is cut only if its asset was loaded preparing the first person.
    public var firstPersonRenderMode: FirstPersonRenderMode = .thirdPerson {
        didSet {
            guard firstPersonRenderMode != oldValue else { return }
            change { visibilityChange = changeStamp }
        }
    }

    /// How each node drawing a mesh draws it, as the model's first-person settings ask.
    private func visibility() -> [Int: GLTFFrameOutput.Visibility] {
        var visibility: [Int: GLTFFrameOutput.Visibility] = [:]
        for (node, meshIndex) in asset.meshIndicesByNode {
            let mesh = asset.meshes[meshIndex]
            let type = firstPerson.annotation(ofNodeAt: node, meshIndex: mesh.meshIndex)
            // An `auto` mesh is cut rather than hidden, so the body below it stays.
            if type == .auto, mesh.geometry.slots.contains(where: { $0.firstPersonIndexRange != nil }) {
                visibility[node] = firstPersonRenderMode == .firstPerson ? .firstPersonCut : .shown
                continue
            }
            // An unskinned mesh cannot be cut, so the head takes it whole.
            let underHead = firstPerson.headNode.map { isSameOrDescendant(node, of: $0) } ?? false
            visibility[node] = type.isHidden(in: firstPersonRenderMode, hidesAutoInFirstPerson: underHead) ? .hidden : .shown
        }
        return visibility
    }

    private func isSameOrDescendant(_ node: Int, of ancestor: Int) -> Bool {
        var current: Int? = node
        while let index = current {
            if index == ancestor { return true }
            current = asset.nodes[index].parent
        }
        return false
    }

    // MARK: - Copies

    /// Another instance of the same asset, standing as this one stands now: its pose, morph
    /// weights, expressions, gaze and first-person view. No animation runs on it.
    public override func snapshot() throws -> VRMInstance {
        let copy = try VRMInstance(asset: asset)
        copyPose(to: copy)
        var weights: [ExpressionKey: Float] = [:]
        for info in availableExpressions {
            weights[info.key] = expression(for: info.key)
        }
        copy.setExpressions(weights)
        copyMorphWeights(to: copy)
        copy.lookAtTarget = lookAtTarget
        copy.firstPersonRenderMode = firstPersonRenderMode
        return copy
    }
}
