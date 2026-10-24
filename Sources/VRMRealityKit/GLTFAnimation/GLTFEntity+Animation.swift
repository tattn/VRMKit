#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit
import VRMKitRuntime

/// Marks a ``GLTFEntity`` with running animations, so ``GLTFAnimationSystem``
/// only visits entities that actually need a tick.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFAnimationPlaybackComponent: Component {}

/// Advances the running glTF animations of every ``GLTFEntity`` once per render frame. A
/// ``VRMEntity`` advances its own as the first step of ``VRMEntity/update(deltaTime:)``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFAnimationSystem: System {
    private static let query = EntityQuery(where: .has(GLTFAnimationPlaybackComponent.self))

    public init(scene: Scene) {}

    public func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let gltf = entity as? GLTFEntity, !(gltf is VRMEntity) else { continue }
            gltf.updateAnimations(deltaTime: context.deltaTime)
        }
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFEntity {
    /// Metadata of the document's animations. Keyframe data stays untouched until
    /// ``playAnimation(at:loops:speed:)``.
    public var animations: [GLTFAnimation] {
        if let cached = animationMetadata { return cached }
        let metadata = gltf.animations.enumerated().map { index, animation in
            GLTFAnimation(index: index, name: animation.name, duration: animationDecoder.duration(of: animation))
        }
        animationMetadata = metadata
        return metadata
    }

    /// Starts playing the animation at `index` and returns its controller.
    ///
    /// Multiple animations can run at once; channels targeting the same node or morph
    /// target apply in playback-start order, so the one started last wins.
    ///
    /// - Throws: when this entity is a clone and so carries no runtime bindings, when
    ///   `index` is out of range, or when the animation's samplers violate the glTF spec.
    @discardableResult
    public func playAnimation(at index: Int, loops: Bool = false, speed: Float = 1) throws -> GLTFAnimationPlaybackController {
        guard let instance else {
            throw VRMError._notSupported(
                "this entity is a copy of a loaded glTF scene and carries no animation bindings; load the scene again to animate it"
            )
        }
        let controller = try instance.playAnimation(at: index, loops: loops, speed: speed)
        didStartPlayback()
        return controller
    }

    /// Puts a playback just started on the render tick, and skins the model once so the
    /// first frame is already correct.
    func didStartPlayback() {
        components.set(GLTFAnimationPlaybackComponent())
        applyInstanceOutput()
        flushDeformation()
    }

    /// Stops every running glTF animation, holding the current pose.
    public func stopAnimations() {
        instance?.stopAnimations()
    }

    /// Advances the running glTF animations by one frame and skins the result.
    ///
    /// ``GLTFAnimationSystem`` calls this once per render frame. Call it yourself only for a
    /// scene that RealityKit does not update. A ``VRMEntity`` advances its animations in
    /// ``VRMEntity/update(deltaTime:)``, so call that instead.
    public func updateAnimations(deltaTime: TimeInterval) {
        adoptNodeEntitiesPosedFromOutside()
        if let instance, instance.animationPlayer.isPlaying {
            instance.animationPlayer.advance(deltaTime: max(0, deltaTime))
            present(instance.takeOutput())
        } else {
            // A clone inherits the marker component but not the instance.
            components.remove(GLTFAnimationPlaybackComponent.self)
        }
        flushDeformation()
    }
}
#endif
