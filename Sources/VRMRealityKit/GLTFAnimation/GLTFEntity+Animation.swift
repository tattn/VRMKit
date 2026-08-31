#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

/// Metadata of one glTF animation, identified by `index`: `name` is optional and
/// may repeat.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFAnimation: Sendable {
    public let index: Int
    public let name: String?
    public let duration: TimeInterval
}

/// What a playback controller drives: one decoded animation bound to what it poses.
/// glTF animations bind entities by node index; VRM animations retarget onto
/// humanoid bones.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
protocol GLTFAnimationApplying: AnyObject {
    /// Poses the bound targets for `time`, appending every node whose transform it
    /// changed to `movedNodes`, so the caller re-solves those joints alone.
    func apply(at time: Float, movedNodes: inout [Entity])
}

/// Controls one running glTF or VRM animation, in the spirit of RealityKit's
/// `AnimationPlaybackController`.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class GLTFAnimationPlaybackController {
    public let animation: GLTFAnimation
    /// Playback rate multiplier. A negative rate plays backwards, starting at the
    /// animation's end rather than at 0. A non-finite rate is refused, since it would
    /// put NaN through every pose it drives.
    public var speed: Float {
        didSet { if !speed.isFinite { speed = oldValue } }
    }
    /// While paused time does not advance, and the pose reached keeps being re-applied.
    public var isPaused = false
    public let loops: Bool
    public private(set) var time: TimeInterval
    /// Set when a non-looping animation reaches its end or ``stop()`` is called.
    public private(set) var isComplete = false

    /// Weak, so a controller kept past its playback does not hold the scene alive.
    private weak var entity: GLTFEntity?
    /// A runtime built for this playback alone is owned here, living exactly as long as
    /// the controller; a cached one is borrowed.
    private weak var runtime: (any GLTFAnimationApplying)?
    private let ownedRuntime: (any GLTFAnimationApplying)?

    init(animation: GLTFAnimation,
         runtime: any GLTFAnimationApplying,
         ownsRuntime: Bool,
         entity: GLTFEntity,
         loops: Bool,
         speed: Float) {
        self.animation = animation
        self.runtime = runtime
        self.ownedRuntime = ownsRuntime ? runtime : nil
        self.entity = entity
        self.loops = loops
        self.speed = speed.isFinite ? speed : 1
        self.time = self.speed < 0 ? animation.duration : 0
    }

    /// Jumps to `time`, clamped into the animation, and applies that pose immediately
    /// without resuming a completed animation. Animations started later still win.
    /// A non-finite time is refused, as a non-finite ``speed`` is.
    public func seek(to newTime: TimeInterval) {
        guard newTime.isFinite else { return }
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

    func advance(deltaTime: TimeInterval, movedNodes: inout [Entity]) {
        guard !isComplete else { return }
        let duration = animation.duration
        // A zero-length animation holds a single pose, which looping cannot change: it
        // completes rather than reapplying it every frame.
        guard duration > 0 else {
            apply(movedNodes: &movedNodes)
            isComplete = true
            return
        }
        // Pausing stops time, not the playback: the pose is re-applied every frame so an
        // animation this one outranks cannot take its targets over.
        if !isPaused {
            time += deltaTime * TimeInterval(speed)
            if loops {
                time = time.truncatingRemainder(dividingBy: duration)
                if time < 0 { time += duration }
            } else if time >= duration || time < 0 {
                time = min(max(time, 0), duration)
                isComplete = true
            }
        }
        apply(movedNodes: &movedNodes)
    }

    /// Poses the model for the current time, collecting the joints it moved.
    func apply(movedNodes: inout [Entity]) {
        runtime?.apply(at: Float(time), movedNodes: &movedNodes)
    }
}

/// Marks a ``GLTFEntity`` with running animations, so ``GLTFAnimationSystem``
/// only visits entities that actually need a tick.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFAnimationPlaybackComponent: Component {}

/// Advances the running glTF animations of every ``GLTFEntity`` once per render frame.
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
        let metadata = (gltf.animations).enumerated().map { index, animation in
            GLTFAnimation(index: index, name: animation.name, duration: animationDecoder.duration(of: animation))
        }
        animationMetadata = metadata
        return metadata
    }

    /// The animations carrying `name`. glTF names may repeat, so any number may match.
    public func animations(named name: String) -> [GLTFAnimation] {
        animations.filter { $0.name == name }
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
        guard hasRuntimeBindings else {
            throw VRMError._notSupported(
                "this entity is a copy of a loaded glTF scene and carries no animation bindings; load the scene again to animate it"
            )
        }
        let metadata = animations
        guard metadata.indices.contains(index) else {
            throw VRMError._dataInconsistent("animation index \(index) is out of range for \(metadata.count) animations")
        }
        return startPlayback(metadata[index],
                             runtime: try animationRuntime(at: index),
                             ownsRuntime: false,
                             loops: loops,
                             speed: speed)
    }

    /// Puts `runtime` on the render tick under a new controller, and poses the model once
    /// so the first frame is already correct.
    ///
    /// - Parameter ownsRuntime: whether the controller is the runtime's only owner, for
    ///   runtimes built per playback rather than cached on the entity.
    func startPlayback(_ animation: GLTFAnimation,
                       runtime: any GLTFAnimationApplying,
                       ownsRuntime: Bool,
                       loops: Bool,
                       speed: Float) -> GLTFAnimationPlaybackController {
        let controller = GLTFAnimationPlaybackController(animation: animation,
                                                         runtime: runtime,
                                                         ownsRuntime: ownsRuntime,
                                                         entity: self,
                                                         loops: loops,
                                                         speed: speed)
        activeAnimationControllers.append(controller)
        components.set(GLTFAnimationPlaybackComponent())
        var movedNodes: [Entity] = []
        controller.apply(movedNodes: &movedNodes)
        if !movedNodes.isEmpty {
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
        movedAnimationNodes.removeAll(keepingCapacity: true)
        for controller in activeAnimationControllers {
            controller.advance(deltaTime: deltaTime, movedNodes: &movedAnimationNodes)
        }
        // A paused or held pose leaves the skeleton where the last solve put it, and a
        // looping animation that rests moves only the joints something else has taken.
        if !movedAnimationNodes.isEmpty {
            invalidateSkinPose(for: movedAnimationNodes)
            // A model driving its own per-frame update solves the pose at the end of it,
            // after this frame's constraints and spring bones.
            if !refreshesSkinningPerFrame {
                flushSkinPoseIfNeeded()
            }
        }
        pruneCompletedAnimations()
    }

    /// Poses the model for a seek: the seeked animation first, then every animation that
    /// outranks it, so a seek cannot break the playback order.
    func applyPose(seekedBy controller: GLTFAnimationPlaybackController) {
        // A stopped controller has left the list, so everything running outranks it.
        let first = activeAnimationControllers.firstIndex { $0 === controller }.map { $0 + 1 } ?? 0
        var movedNodes: [Entity] = []
        controller.apply(movedNodes: &movedNodes)
        for outranking in activeAnimationControllers[first...] {
            outranking.apply(movedNodes: &movedNodes)
        }
        if !movedNodes.isEmpty {
            flushSkinPose()
        }
    }

    func pruneCompletedAnimations() {
        activeAnimationControllers.removeAll(where: \.isComplete)
        if activeAnimationControllers.isEmpty {
            components.remove(GLTFAnimationPlaybackComponent.self)
        }
    }

    private func animationRuntime(at index: Int) throws -> GLTFAnimationRuntime {
        if let cached = animationRuntimes[index] { return cached }
        let animation = try gltf.load(\.animations, at: index)
        let runtime = try GLTFAnimationRuntime(animation: animation, entity: self)
        animationRuntimes[index] = runtime
        return runtime
    }
}
#endif
