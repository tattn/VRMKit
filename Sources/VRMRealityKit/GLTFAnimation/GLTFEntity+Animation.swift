#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

/// Metadata of one glTF animation. `index` is its canonical identity; `name` is
/// optional and may repeat.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFAnimation: Sendable {
    public let index: Int
    public let name: String?
    public let duration: TimeInterval
}

/// Controls one running glTF animation, in the spirit of RealityKit's
/// `AnimationPlaybackController`.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class GLTFAnimationPlaybackController {
    public let animation: GLTFAnimation
    /// Playback rate multiplier. A negative rate plays backwards; starting a
    /// playback with one begins at the animation's end rather than at 0.
    public var speed: Float
    /// While paused the pose holds and time does not advance.
    public var isPaused = false
    public let loops: Bool
    public private(set) var time: TimeInterval
    /// Set when a non-looping animation reaches its end or ``stop()`` is called.
    public private(set) var isComplete = false

    /// Both are weak: the entity owns the runtime and the entity graph it poses,
    /// so a controller the caller keeps past its playback holds neither alive.
    private weak var runtime: GLTFAnimationRuntime?
    private weak var entity: GLTFEntity?

    init(animation: GLTFAnimation,
         runtime: GLTFAnimationRuntime,
         entity: GLTFEntity,
         loops: Bool,
         speed: Float) {
        self.animation = animation
        self.runtime = runtime
        self.entity = entity
        self.loops = loops
        self.speed = speed
        self.time = speed < 0 ? animation.duration : 0
    }

    /// Jumps to `time` (clamped into the animation) and applies that pose
    /// immediately, without resuming a completed animation.
    ///
    /// Animations started later still win over the seeked one, exactly as they
    /// do on a render tick.
    public func seek(to newTime: TimeInterval) {
        time = min(max(newTime, 0), animation.duration)
        entity?.applyPose(seekedBy: self)
    }

    /// Ends playback, holding the current pose.
    public func stop() {
        markComplete()
        entity?.pruneCompletedAnimations()
    }

    func markComplete() {
        isComplete = true
    }

    @discardableResult
    func advance(deltaTime: TimeInterval) -> Bool {
        guard !isPaused, !isComplete else { return false }
        let duration = animation.duration
        // A zero-length animation holds a single pose, which looping cannot
        // change: it completes rather than reapplying it for every frame to come.
        guard duration > 0 else {
            let moved = apply()
            isComplete = true
            return moved
        }
        time += deltaTime * TimeInterval(speed)
        if loops {
            time = time.truncatingRemainder(dividingBy: duration)
            if time < 0 { time += duration }
        } else if time >= duration || time < 0 {
            time = min(max(time, 0), duration)
            isComplete = true
        }
        return apply()
    }

    /// Poses the model for the current time, reporting whether joints moved.
    @discardableResult
    func apply() -> Bool {
        runtime?.apply(at: Float(time)) ?? false
    }
}

/// Marks a ``GLTFEntity`` with running animations, so ``GLTFAnimationSystem``
/// only visits entities that actually need a tick.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFAnimationPlaybackComponent: Component {}

/// Advances the running glTF animations of every ``GLTFEntity`` once per render
/// frame.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFAnimationSystem: System {
    private static let query = EntityQuery(where: .has(GLTFAnimationPlaybackComponent.self))

    public init(scene: Scene) {}

    public func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            (entity as? GLTFEntity)?.updateAnimations(deltaTime: context.deltaTime)
        }
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFEntity {
    /// Metadata of the document's animations. Keyframe data stays untouched until
    /// ``playAnimation(at:loops:speed:)``.
    public var animations: [GLTFAnimation] {
        if let cached = animationMetadata { return cached }
        let metadata = (gltf.animations ?? []).enumerated().map { index, animation in
            GLTFAnimation(index: index, name: animation.name, duration: duration(of: animation))
        }
        animationMetadata = metadata
        return metadata
    }

    /// The animations carrying `name`. glTF names may repeat, so this can return
    /// any number of them.
    public func animations(named name: String) -> [GLTFAnimation] {
        animations.filter { $0.name == name }
    }

    /// Starts playing the animation at `index` and returns its controller.
    ///
    /// Multiple animations can run at once; channels targeting the same node or
    /// morph target apply in playback-start order, so the one started last wins.
    ///
    /// - Throws: when this entity is a clone and so carries no runtime bindings,
    ///   when `index` is out of range, or when the animation's samplers violate
    ///   the glTF spec (non-increasing keyframe times, an output whose length
    ///   does not match its interpolation).
    @discardableResult
    public func playAnimation(at index: Int, loops: Bool = false, speed: Float = 1) throws -> GLTFAnimationPlaybackController {
        guard hasRuntimeBindings else {
            throw VRMError._notSupported(
                "this entity is a copy of a loaded glTF scene and carries no animation bindings; load the scene again to animate it"
            )
        }
        let metadata = animations
        guard metadata.indices.contains(index) else {
            throw VRMError._dataInconsistent("animation index \(index) is out of range for \(metadata.count) animations")
        }
        let runtime = try animationRuntime(at: index)
        let controller = GLTFAnimationPlaybackController(animation: metadata[index],
                                                         runtime: runtime,
                                                         entity: self,
                                                         loops: loops,
                                                         speed: speed)
        activeAnimationControllers.append(controller)
        components.set(GLTFAnimationPlaybackComponent())
        // The first frame is correct immediately, not one render tick later.
        if controller.apply() {
            flushSkinPose()
        }
        return controller
    }

    /// Stops every running glTF animation, holding the current pose.
    public func stopAnimations() {
        for controller in activeAnimationControllers {
            controller.markComplete()
        }
        pruneCompletedAnimations()
    }

    func updateAnimations(deltaTime: TimeInterval) {
        // A clone inherits the marker component but not the controllers.
        guard !activeAnimationControllers.isEmpty else {
            components.remove(GLTFAnimationPlaybackComponent.self)
            return
        }
        var movedTransforms = false
        for controller in activeAnimationControllers {
            movedTransforms = controller.advance(deltaTime: deltaTime) || movedTransforms
        }
        // A paused or held pose leaves the skeleton where the last solve put it.
        if movedTransforms, !refreshesSkinningPerFrame {
            flushSkinPose()
        }
        pruneCompletedAnimations()
    }

    /// Poses the model for a seek: the seeked animation first, then every
    /// animation that outranks it, so a seek cannot break the playback order.
    func applyPose(seekedBy controller: GLTFAnimationPlaybackController) {
        // A stopped controller has left the list, so everything running outranks it.
        let first = activeAnimationControllers.firstIndex { $0 === controller }.map { $0 + 1 } ?? 0
        var moved = controller.apply()
        for outranking in activeAnimationControllers[first...] {
            moved = outranking.apply() || moved
        }
        if moved {
            flushSkinPose()
        }
    }

    func pruneCompletedAnimations() {
        activeAnimationControllers.removeAll(where: \.isComplete)
        if activeAnimationControllers.isEmpty {
            components.remove(GLTFAnimationPlaybackComponent.self)
        }
    }

    /// Re-solves the skin pose from the current joint transforms.
    func flushSkinPose() {
        guard !skinBindings.isEmpty else { return }
        updateSkinning()
    }

    private func animationRuntime(at index: Int) throws -> GLTFAnimationRuntime {
        if let cached = animationRuntimes[index] { return cached }
        let animation = try gltf.load(\.animations, at: index)
        let runtime = try GLTFAnimationRuntime(animation: animation, entity: self)
        animationRuntimes[index] = runtime
        return runtime
    }

    /// The animation's length: the input accessors' spec-required `max` when
    /// present, decoded input times otherwise.
    private func duration(of animation: GLTF.Animation) -> TimeInterval {
        var duration: Float = 0
        for sampler in animation.samplers {
            guard let accessor = try? gltf.load(\.accessors, at: sampler.input) else { continue }
            if let max = accessor.max?.first {
                duration = Swift.max(duration, max)
            } else if let last = try? animationDecoder.times(at: sampler.input).last {
                duration = Swift.max(duration, last)
            }
        }
        return TimeInterval(duration)
    }
}
#endif
