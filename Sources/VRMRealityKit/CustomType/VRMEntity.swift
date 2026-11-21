#if canImport(RealityKit)
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

/// The root entity of a loaded VRM model, drawing the ``VRMInstance`` that moves it: its
/// expressions, gaze, spring bones, first-person view and humanoid bones are the instance's.
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

    /// What moves the model, as the VRM instance it is. Nil on a `clone(recursive:)` copy, which
    /// only renders.
    public override var instance: VRMInstance? { vrmInstance }
    private var vrmInstance: VRMInstance?
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

    /// The entity built for the node of a humanoid bone, nil for a bone the model does not have.
    public func entity(for bone: HumanoidBone) -> Entity? {
        vrmInstance?.node(for: bone).flatMap(entity(forNodeAt:))
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
        instance.update(deltaTime: deltaTime)
        flushDeformation()
    }

    /// Advances only what follows the pose: node constraints, the gaze and spring bones, then
    /// skins the result. No animation advances and no update handler runs, so a pose held still
    /// keeps its shape while its spring bones settle.
    public func updateSecondaryMotion(deltaTime: TimeInterval) {
        guard let instance = vrmInstance else { return }
        refreshPoseRoot()
        adoptNodeEntitiesPosedFromOutside()
        instance.updateSecondaryMotion(deltaTime: deltaTime)
        flushDeformation()
    }

    /// Runs `handler` at `stage` of every ``update(deltaTime:)``, with the frame's time, in
    /// place of the one set there before; nil removes it. This is where code that poses the
    /// model every frame, such as tracking or IK, fits into the frame.
    ///
    /// Unlike ``VRMInstance/setUpdateHandler(_:at:)``, the handler runs on the main actor, and the
    /// entity may move in it: the runtimes after it read where the entity then stands.
    public func setUpdateHandler(_ handler: (@MainActor (TimeInterval) -> Void)?, at stage: VRMUpdateStage) {
        vrmInstance?.setUpdateHandler(handler.map { handler in
            { [weak self] deltaTime in
                MainActor.assumeIsolated {
                    handler(deltaTime)
                    if stage == .afterAnimation {
                        self?.refreshPoseRoot()
                    }
                }
            }
        }, at: stage)
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
