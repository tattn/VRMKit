#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat
import VRMKit

/// Metadata of one glTF animation, identified by `index`: `name` is optional and
/// may repeat.
public struct GLTFAnimation: Sendable {
    public let index: Int
    public let name: String?
    public let duration: TimeInterval

    package init(index: Int, name: String?, duration: TimeInterval) {
        self.index = index
        self.name = name
        self.duration = duration
    }
}

/// What playing animations set beyond the pose, for the model to pass on. Animations
/// applied later in a frame overwrite what earlier ones set.
package struct GLTFAnimationOutput {
    /// glTF node → the weights of the morph targets of the mesh it draws.
    package var morphWeights: [Int: [Float]] = [:]
    package var expressionWeights: [ExpressionKey: Float] = [:]
    /// The gaze as the rotation of the look-at origin.
    package var gaze: simd_quatf?

    package init() {}

    package var isEmpty: Bool {
        morphWeights.isEmpty && expressionWeights.isEmpty && gaze == nil
    }
}

/// What a playback controller drives: one decoded animation bound to what it poses.
/// glTF animations bind nodes by index; VRM animations retarget onto humanoid bones.
package protocol GLTFAnimationApplying: AnyObject {
    /// Poses the bound nodes for `time` in `pose`, which notes the nodes that moved, and
    /// sets in `output` what the animation drives beyond the pose.
    func apply(at time: Float, to pose: GLTFPose, output: inout GLTFAnimationOutput)
}

/// Controls one running glTF or VRM animation, in the spirit of RealityKit's
/// `AnimationPlaybackController`.
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

    /// Weak, so a controller kept past its playback does not hold the model alive.
    private weak var player: GLTFAnimationPlayer?
    /// A runtime built for this playback alone is owned here, living exactly as long as
    /// the controller; a cached one is borrowed.
    private weak var runtime: (any GLTFAnimationApplying)?
    private let ownedRuntime: (any GLTFAnimationApplying)?

    init(animation: GLTFAnimation,
         runtime: any GLTFAnimationApplying,
         ownsRuntime: Bool,
         player: GLTFAnimationPlayer,
         loops: Bool,
         speed: Float) {
        self.animation = animation
        self.runtime = runtime
        self.ownedRuntime = ownsRuntime ? runtime : nil
        self.player = player
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
        player?.applyPose(seekedBy: self)
    }

    /// Ends playback, holding the current pose.
    public func stop() {
        isComplete = true
        player?.pruneCompleted()
    }

    func markComplete() {
        isComplete = true
    }

    func advance(deltaTime: TimeInterval, output: inout GLTFAnimationOutput) {
        guard !isComplete else { return }
        let duration = animation.duration
        // A zero-length animation holds a single pose, which looping cannot change: it
        // completes rather than reapplying it every frame.
        guard duration > 0 else {
            apply(output: &output)
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
        apply(output: &output)
    }

    /// Poses the model for the current time.
    func apply(output: inout GLTFAnimationOutput) {
        guard let pose = player?.pose else { return }
        runtime?.apply(at: Float(time), to: pose, output: &output)
    }
}

/// The animations running on one model, applied in the order they started so the one
/// started last wins what they share.
package final class GLTFAnimationPlayer {
    package let pose: GLTFPose
    private var controllers: [GLTFAnimationPlaybackController] = []
    /// Passes on what an apply set beyond the pose: the morph weights, the expressions and
    /// the gaze.
    package var didApply: ((GLTFAnimationOutput) -> Void)?
    /// Called once a seek has posed the model outside a frame update, for the model to
    /// show the result.
    package var didSeek: (() -> Void)?
    /// Called once the last controller has completed.
    package var didFinish: (() -> Void)?

    package init(pose: GLTFPose) {
        self.pose = pose
    }

    package var isPlaying: Bool { !controllers.isEmpty }

    /// Starts `runtime` under a new controller, and poses the model once so the first frame
    /// is already correct.
    ///
    /// - Parameter ownsRuntime: whether the controller is the runtime's only owner, for
    ///   runtimes built per playback rather than cached by the model.
    package func start(_ animation: GLTFAnimation,
                       runtime: any GLTFAnimationApplying,
                       ownsRuntime: Bool,
                       loops: Bool,
                       speed: Float) -> GLTFAnimationPlaybackController {
        let controller = GLTFAnimationPlaybackController(animation: animation,
                                                         runtime: runtime,
                                                         ownsRuntime: ownsRuntime,
                                                         player: self,
                                                         loops: loops,
                                                         speed: speed)
        controllers.append(controller)
        var output = GLTFAnimationOutput()
        controller.apply(output: &output)
        pass(output)
        return controller
    }

    /// Moves every running animation on by `deltaTime` and poses the model for it.
    package func advance(deltaTime: TimeInterval) {
        var output = GLTFAnimationOutput()
        for controller in controllers {
            controller.advance(deltaTime: deltaTime, output: &output)
        }
        pass(output)
        pruneCompleted()
    }

    /// Poses the model for a seek: the seeked animation first, then every animation that
    /// outranks it, so a seek cannot break the playback order.
    func applyPose(seekedBy controller: GLTFAnimationPlaybackController) {
        // A stopped controller has left the list, so everything running outranks it.
        let first = controllers.firstIndex { $0 === controller }.map { $0 + 1 } ?? 0
        var output = GLTFAnimationOutput()
        controller.apply(output: &output)
        for outranking in controllers[first...] {
            outranking.apply(output: &output)
        }
        pass(output)
        didSeek?()
    }

    /// Ends every running animation, holding the current pose.
    package func stopAll() {
        for controller in controllers {
            controller.markComplete()
        }
        pruneCompleted()
    }

    func pruneCompleted() {
        let wasPlaying = isPlaying
        controllers.removeAll(where: \.isComplete)
        if wasPlaying, !isPlaying {
            didFinish?()
        }
    }

    private func pass(_ output: GLTFAnimationOutput) {
        guard !output.isEmpty else { return }
        didApply?(output)
    }
}
