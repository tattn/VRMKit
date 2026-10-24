#if canImport(RealityKit)
import Foundation
import RealityKit
import VRMKit
import VRMKitRuntime

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
        guard let instance = vrmInstance else {
            throw VRMError._notSupported(
                "this entity is a copy of a loaded VRM scene and carries no animation bindings; load the scene again to animate it"
            )
        }
        let controller = try instance.playAnimation(animation, animationIndex: animationIndex, loops: loops, speed: speed)
        didStartPlayback()
        return controller
    }
}
#endif
