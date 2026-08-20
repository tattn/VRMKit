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
/// per-frame code on the caller's side. To run your own animation code in a
/// guaranteed order relative to the VRM update — for example, posing joints that
/// this frame's skinning should already reflect — declare it in a custom
/// `System` with `SystemDependency.before(VRMUpdateSystem.self)`.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct VRMUpdateSystem: System {
    /// Runs after the glTF animation tick, so the VRM runtime sees this frame's
    /// animated pose.
    public static var dependencies: [SystemDependency] { [.after(GLTFAnimationSystem.self)] }

    private static let query = EntityQuery(where: .has(VRMUpdateComponent.self))

    public init(scene: Scene) {}

    public func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let vrmEntity = entity as? VRMEntity else { continue }
            // A clone inherits the marker component but not the runtime bindings
            // `update(deltaTime:)` drives, so it has nothing left to tick.
            guard vrmEntity.hasRuntimeBindings else {
                vrmEntity.components.remove(VRMUpdateComponent.self)
                continue
            }
            vrmEntity.update(deltaTime: context.deltaTime)
        }
    }
}
#endif
