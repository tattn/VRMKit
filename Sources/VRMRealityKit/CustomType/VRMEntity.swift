#if canImport(RealityKit)
import CoreGraphics
import Foundation
import OSLog
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

/// Carries the loaded VRM on the entity, so `clone(recursive:)` copies still answer
/// ``VRMEntity/vrm``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct VRMComponent: Component {
    let vrm: VRM
}

/// The root entity of a loaded VRM model, drawing a ``VRMInstance`` that moves it.
///
/// A plain `Entity`, so adding it to a scene is all its lifetime needs: the parent
/// owns it, and ``VRMUpdateSystem`` animates it while it stays in the scene.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public final class VRMEntity: GLTFEntity {
    private static let logger = Logger(subsystem: "com.github.tattn.VRMKit", category: "Expression")

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

    /// ``GLTFEntity/instance``, as the VRM instance it is.
    private(set) var vrmInstance: VRMInstance?
    /// The entities drawing the mesh of each node, which the instance shows, hides or cuts.
    private var meshEntitiesByNode: [Int: [Entity]] = [:]

    /// Registers the components and system this entity relies on, exactly once per process.
    /// RealityKit instantiates a registered system for every scene, existing ones included,
    /// so registering on first use is enough.
    @MainActor private static let registerRealityKitTypes: Void = {
        VRMComponent.registerComponent()
        VRMUpdateComponent.registerComponent()
        VRMUpdateSystem.registerSystem()
    }()

    init(vrm: VRM, document: GLTFDocument, sceneIndex: Int, outputColorSpace: GLTFOutputColorSpace) {
        super.init(document: document, sceneIndex: sceneIndex, outputColorSpace: outputColorSpace)
        _ = Self.registerRealityKitTypes
        components.set(VRMComponent(vrm: vrm))
        components.set(VRMUpdateComponent())
    }

    /// Also builds the `clone(recursive:)` copies, which inherit the ``VRMComponent``
    /// but not the runtime bindings, so they only render.
    public required init() {
        super.init()
        _ = Self.registerRealityKitTypes
    }

    /// Whether ``VRMUpdateSystem`` calls ``update(deltaTime:)`` on every render frame.
    /// Enabled by default; disable it to drive the timing yourself.
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

    /// How the spring bones swing: the wind pushing them, if any.
    public var springBoneConfiguration: SpringBoneConfiguration {
        get { vrmInstance?.springBoneConfiguration ?? SpringBoneConfiguration() }
        set { vrmInstance?.springBoneConfiguration = newValue }
    }

    /// Forgets the motion the spring bones carry between frames, so the next update
    /// starts them at rest. Call it after teleporting the model.
    public func resetSpringBones() {
        vrmInstance?.resetSpringBones()
    }

    /// Has `center` carry `share` of its motion into the tail of the spring-bone joint on
    /// `joint`, where a spring's center carries all of it: 0 swings the joint as if it had
    /// no center and 1 as if `center` were its spring's center. It takes the place of the
    /// spring's center for that joint, and the spring bones start again at rest.
    ///
    /// `center` has to be above the joint, and no spring may swing it, as for a spring's center.
    public func setSpringBoneCenter(_ center: Entity, share: Float, forJoint joint: Entity) throws {
        guard let instance = vrmInstance, let centerIndex = nodeIndex(of: center), let jointIndex = nodeIndex(of: joint) else {
            throw VRMError._dataInconsistent("a spring-bone center and its joint have to be nodes of this model")
        }
        try instance.setSpringBoneCenter(centerIndex, share: share, forJoint: jointIndex)
    }

    /// The versions disagree about which way a model faces, and loading converts no
    /// coordinates, so the entity faces whichever way its VRM does.
    public override var frontDirection: SIMD3<Float> {
        if let frontDirectionCache { return frontDirectionCache }
        let direction = vrm.forwardDirection
        frontDirectionCache = direction
        return direction
    }

    /// ``vrm`` is looked up in a component on every read, and apps ask for the front every
    /// frame. A copy does not carry it over, so it reads its own.
    private var frontDirectionCache: SIMD3<Float>?

    /// Called once per entity, right after its node hierarchy is built: the instance moves
    /// the pose the node entities copy, and this entity draws the rest of what it hands back.
    func setUpInstance(asset: GLTFAsset,
                       built: GLTFSceneBuilder.BuiltScene,
                       builder: GLTFSceneBuilder) throws {
        guard let pose else {
            throw VRMError._dataInconsistent("a VRM entity needs its pose before its instance")
        }
        humanoid.setUp(boneNodes: vrm.boneNodes, nodes: built.nodes)
        for sceneMesh in built.meshes.values.joined() {
            meshEntitiesByNode[sceneMesh.nodeIndex, default: []].append(sceneMesh.entity)
        }
        let instance = try VRMInstance(asset: asset, pose: pose, materialBase: materialBase(builder: builder))
        vrmInstance = instance
        adoptInstance(instance)
    }

    /// What an expression's material bind starts from: what the RealityKit material draws
    /// with, unless a state animating the value keeps it.
    private func materialBase(builder: GLTFSceneBuilder) -> VRMInstance.MaterialBase {
        VRMInstance.MaterialBase(
            color: { [unowned self] index, type in
                MainActor.assumeIsolated {
                    // A malformed bind only invalidates itself, never the whole load.
                    guard let color = try? currentMaterialColor(withMaterialIndex: index, type: type, builder: builder) else {
                        Self.logger.warning("Skipping invalid MaterialColorBind. materialIndex=\(index)")
                        return nil
                    }
                    return color
                }
            },
            uvTransform: { [unowned self] index in
                MainActor.assumeIsolated {
                    guard let base = try? currentTextureTransform(withMaterialIndex: index, builder: builder) else {
                        Self.logger.warning("Skipping invalid TextureTransformBind. materialIndex=\(index)")
                        return nil
                    }
                    return (base.scale, base.offset, base.rotation)
                }
            }
        )
    }

    /// What the eyes follow, nil to leave them at rest.
    ///
    /// A world-space position is kept on as either it or the model moves, so a model
    /// looking at the camera only has to be told where the camera is. A model stating no
    /// look-at keeps its eyes still whatever this is set to.
    public var lookAtTarget: LookAtTarget? {
        get { vrmInstance?.lookAtTarget }
        set {
            guard let instance = vrmInstance else { return }
            refreshPoseRoot()
            instance.lookAtTarget = newValue
            applyInstanceOutput(solvingSkins: false)
        }
    }

    /// The color a `materialColorBind` starts from. A state animating that color keeps
    /// it; everything else reads it from the RealityKit material.
    func currentMaterialColor(withMaterialIndex index: Int,
                              type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                              builder: GLTFSceneBuilder) throws -> SIMD4<Float> {
        if let color = materialStates[index]?.animatable?.color(for: type) {
            return color
        }
        return try builder.material(withMaterialIndex: index).currentColor(for: type, in: outputColorSpace)
    }

    /// The UV transform a `textureTransformBind` starts from. A state animating it keeps
    /// it; everything else reads it from the RealityKit material.
    func currentTextureTransform(withMaterialIndex index: Int,
                                 builder: GLTFSceneBuilder) throws -> MaterialParameterTypes.TextureCoordinateTransform {
        if let transform = materialStates[index]?.animatable?.textureTransform {
            return transform
        }
        return try builder.material(withMaterialIndex: index).currentTextureTransform
    }

    /// Advances the model by one frame: its animations, the code set with
    /// ``setUpdateHandler(_:at:)``, node constraints, the gaze, spring bones and skinning, in
    /// that order.
    ///
    /// ``VRMUpdateSystem`` calls this once per render frame, so set
    /// ``isAutomaticUpdateEnabled`` to `false` before driving the timing manually. A bone
    /// posed through ``GLTFEntity/pose`` needs nothing more; one posed on its entity has to
    /// be followed by ``GLTFEntity/invalidateSkinPose()``.
    public func update(deltaTime: TimeInterval) {
        guard let instance = vrmInstance else { return }
        refreshPoseRoot()
        adoptNodeEntitiesPosedFromOutside()
        present(instance.update(deltaTime: deltaTime))
        flushDeformation()
    }

    /// Advances only what follows the pose: node constraints, the gaze and spring bones, then
    /// skins the result. No animation advances and no update handler runs, so a pose held still
    /// keeps its shape while its spring bones settle.
    public func updateSecondaryMotion(deltaTime: TimeInterval) {
        guard let instance = vrmInstance else { return }
        refreshPoseRoot()
        adoptNodeEntitiesPosedFromOutside()
        present(instance.updateSecondaryMotion(deltaTime: deltaTime))
        flushDeformation()
    }

    /// Runs `handler` at `stage` of every ``update(deltaTime:)``, with the frame's time, in
    /// place of the one set there before; nil removes it. This is where code that poses the
    /// model every frame, such as tracking or IK, fits into the frame.
    public func setUpdateHandler(_ handler: (@MainActor (TimeInterval) -> Void)?, at stage: VRMUpdateStage) {
        vrmInstance?.setUpdateHandler(handler.map { handler in
            { [unowned self] deltaTime in
                MainActor.assumeIsolated {
                    handler(deltaTime)
                    // The handler may have moved the model, which the runtimes after it measure from.
                    if stage == .afterAnimation {
                        refreshPoseRoot()
                    }
                }
            }
        }, at: stage)
    }

    public func setExpression(value: CGFloat, for key: ExpressionKey) {
        setExpressions([key: value])
    }

    /// Sets several expression weights and re-applies the result once. Applying
    /// re-accumulates every active clip, so prefer this over repeated
    /// ``setExpression(value:for:)`` calls in one frame.
    public func setExpressions(_ weights: [ExpressionKey: CGFloat]) {
        guard let instance = vrmInstance else { return }
        instance.setExpressions(weights.mapValues { Float($0) })
        applyInstanceOutput(solvingSkins: false)
    }

    /// The handle to set `key` with in ``ExpressionWeights``, or nil when the model offers no such
    /// expression. Look it up once: a handle holds for as long as the model.
    public func expressionHandle(for key: ExpressionKey) -> ExpressionHandle? {
        vrmInstance?.expressionHandle(for: key)
    }

    /// Expression weights for this model, none set yet, to set by handle and hand to
    /// ``setExpressions(_:)-(ExpressionWeights)`` every frame.
    public func makeExpressionWeights() -> ExpressionWeights {
        vrmInstance?.makeExpressionWeights() ?? ExpressionWeights(count: 0)
    }

    /// Sets the weights `weights` sets and re-applies the result once, for a caller driving the
    /// face every frame, which then hashes no key. `weights` has to come from this model's
    /// ``makeExpressionWeights()``.
    public func setExpressions(_ weights: ExpressionWeights) {
        guard let instance = vrmInstance else { return }
        instance.setExpressions(weights)
        applyInstanceOutput(solvingSkins: false)
    }

    public func expression(for key: ExpressionKey) -> CGFloat {
        CGFloat(vrmInstance?.expression(for: key) ?? 0)
    }

    /// The expressions the model offers, each paired with the name it states them
    /// under.
    ///
    /// A VRM 0.x model's blend shape groups come in its own order; a VRM 1.0
    /// model's presets come first, then its custom expressions by name.
    public var availableExpressions: [ExpressionInfo] {
        vrmInstance?.availableExpressions ?? []
    }

    public func setFirstPersonRenderMode(_ mode: FirstPersonRenderMode) {
        guard let instance = vrmInstance else { return }
        instance.firstPersonRenderMode = mode
        applyInstanceOutput(solvingSkins: false)
    }

    override func apply(_ output: GLTFFrameOutput) {
        super.apply(output)
        if !output.materialValues.isEmpty {
            for (materialIndex, values) in output.materialValues {
                for (type, color) in values.colors {
                    applyMaterialColor(color, type: type, materialIndex: materialIndex)
                }
                if let uvTransform = values.uvTransform {
                    applyTextureTransform(scale: uvTransform.scale,
                                          offset: uvTransform.offset,
                                          rotation: uvTransform.rotation,
                                          materialIndex: materialIndex)
                }
            }
            flushDirtyMaterialStates()
        }
        for (nodeIndex, visibility) in output.visibility {
            for entity in meshEntitiesByNode[nodeIndex] ?? [] {
                show(entity, as: visibility)
            }
        }
    }

    /// The cut is baked per part, so a mesh worn head to foot keeps its body while the
    /// head's parts and triangles go.
    private func show(_ entity: Entity, as visibility: GLTFFrameOutput.Visibility) {
        for modelEntity in entity.modelEntitiesInHierarchy where modelEntity.deformedMesh?.hasFirstPersonCut == true {
            modelEntity.setMergedFirstPerson(visibility == .firstPersonCut)
        }
        entity.isEnabled = visibility != .hidden
    }

    private func applyTextureTransform(scale: SIMD2<Float>,
                                       offset: SIMD2<Float>,
                                       rotation: Float,
                                       materialIndex: Int) {
        applyMaterialValue(ofMaterial: materialIndex,
                           toState: { $0.setTextureTransform(scale: scale, offset: offset, rotation: rotation) },
                           toMaterial: { $0.settingTextureTransform(scale: scale, offset: offset, rotation: rotation) })
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

    func currentColor(for type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                      in outputColorSpace: GLTFOutputColorSpace) -> SIMD4<Float> {
        switch self {
        case let material as UnlitMaterial:
            switch type {
            case .color:
                return outputColorSpace.components(of: material.color.tint)
            case .emissionColor, .shadeColor, .matcapColor, .rimColor, .outlineColor:
                return SIMD4<Float>(1, 1, 1, 1)
            }
        case let material as PhysicallyBasedMaterial:
            switch type {
            case .color:
                return outputColorSpace.components(of: material.baseColor.tint)
            case .emissionColor:
                return outputColorSpace.components(of: material.emissiveColor.color)
            // MToon-only colors have no meaning on the PBR fallback material.
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
