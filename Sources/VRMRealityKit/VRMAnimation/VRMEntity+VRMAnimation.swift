#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension VRMEntity {
    /// Starts playing a VRM animation (`.vrma`), retargeted onto this model's
    /// humanoid bones and expressions, and returns its controller.
    ///
    /// Any VRM drives this way, 1.0 and 0.x alike, whatever model the
    /// animation was authored on. Channels the model cannot follow, such as
    /// bones it does not have, are skipped.
    ///
    /// Multiple animations can run at once, glTF ones included; targets they
    /// share apply in playback-start order, so the one started last wins.
    ///
    /// - Parameters:
    ///   - animation: A parsed `.vrma` file.
    ///   - animationIndex: Index into the file's glTF animations. A `.vrma`
    ///     normally carries exactly one, so it defaults to the first.
    /// - Throws: when this entity is a clone and so carries no runtime
    ///   bindings, when the file has no animation at `animationIndex`, or when
    ///   the animation's samplers violate the glTF spec.
    @discardableResult
    public func playAnimation(_ animation: VRMAnimation,
                              animationIndex: Int = 0,
                              loops: Bool = false,
                              speed: Float = 1) throws -> GLTFAnimationPlaybackController {
        guard hasRuntimeBindings else {
            throw VRMError._notSupported(
                "this entity is a copy of a loaded VRM scene and carries no animation bindings; load the scene again to animate it"
            )
        }
        // Retargeting is specific to this (animation, model) pair, so unlike a
        // glTF runtime it is built per playback and owned by its controller.
        let runtime = try VRMAnimationRuntime(animation: animation,
                                              animationIndex: animationIndex,
                                              entity: self)
        return startPlayback(GLTFAnimation(index: animationIndex,
                                           name: runtime.name,
                                           duration: runtime.duration),
                             runtime: runtime,
                             ownsRuntime: true,
                             loops: loops,
                             speed: speed)
    }
}
#endif
