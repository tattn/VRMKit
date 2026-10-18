#if canImport(RealityKit)
import Foundation
import RealityKit

/// Marks a ``VRMEntity`` as driven by ``VRMUpdateSystem``, which advances its
/// skinning, constraints, and spring bones once per frame.
///
/// ``VRMEntity`` attaches this component to itself automatically; the public
/// knob is ``VRMEntity/isAutomaticUpdateEnabled``, since the component does
/// nothing on any other entity.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct VRMUpdateComponent: Component {}

/// Calls ``VRMEntity/update(deltaTime:)`` for every ``VRMEntity`` in the scene
/// on each render frame.
///
/// The system is registered automatically the first time a ``VRMEntity`` is
/// created, so a model animates as soon as it is added to a scene, without any
/// per-frame code on the caller's side. To pose the model from your own code at a
/// fixed point of the frame, such as after its animations and before its spring
/// bones, set it with ``VRMEntity/setUpdateHandler(_:at:)``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct VRMUpdateSystem: System {
    /// Runs after the glTF animation tick, so a glTF model attached under a VRM model, such
    /// as an animated prop, is posed before the VRM model's spring bones collide with it.
    public static var dependencies: [SystemDependency] { [.after(GLTFAnimationSystem.self)] }

    private static let query = EntityQuery(where: .has(VRMUpdateComponent.self))

    public init(scene: Scene) {}

    public func update(context: SceneUpdateContext) {
        // Taking the queried component off an entity mid-walk is not something RealityKit
        // defines, so it waits until the walk is done.
        var untickable: [VRMEntity] = []
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let vrmEntity = entity as? VRMEntity else { continue }
            // A clone inherits the marker component but not the runtime bindings
            // `update(deltaTime:)` drives, so it has nothing left to tick.
            guard vrmEntity.hasRuntimeBindings else {
                untickable.append(vrmEntity)
                continue
            }
            vrmEntity.update(deltaTime: context.deltaTime)
        }
        for entity in untickable {
            entity.components.remove(VRMUpdateComponent.self)
        }
    }
}
#endif
