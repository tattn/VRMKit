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
        guard hasRuntimeBindings else {
            throw VRMError._notSupported(
                "this entity is a copy of a loaded glTF scene and carries no animation bindings; load the scene again to animate it"
            )
        }
        let metadata = animations
        guard metadata.indices.contains(index) else {
            throw VRMError._dataInconsistent("animation index \(index) is out of range for \(metadata.count) animations")
        }
        let controller = try animationPlayer().start(metadata[index],
                                                     runtime: try animationRuntime(at: index),
                                                     ownsRuntime: false,
                                                     loops: loops,
                                                     speed: speed)
        didStartPlayback()
        return controller
    }

    /// Puts a playback just started on the render tick, and skins the model once so the
    /// first frame is already correct.
    func didStartPlayback() {
        components.set(GLTFAnimationPlaybackComponent())
        applyPlaybackOutput()
        flushDeformation()
    }

    /// Stops every running glTF animation, holding the current pose.
    public func stopAnimations() {
        activeAnimationPlayer?.stopAll()
    }

    /// Advances the running glTF animations by one frame and skins the result.
    ///
    /// ``GLTFAnimationSystem`` calls this once per render frame. Call it yourself only for a
    /// scene that RealityKit does not update. A ``VRMEntity`` advances its animations in
    /// ``VRMEntity/update(deltaTime:)``, so call that instead.
    public func updateAnimations(deltaTime: TimeInterval) {
        adoptNodeEntitiesPosedFromOutside()
        advanceAnimations(deltaTime: deltaTime)
        flushDeformation()
    }

    /// Moves every running animation on by `deltaTime` and poses the model for it.
    func advanceAnimations(deltaTime: TimeInterval) {
        // A clone inherits the marker component but not the player.
        guard let player = activeAnimationPlayer, player.isPlaying else {
            components.remove(GLTFAnimationPlaybackComponent.self)
            return
        }
        player.advance(deltaTime: deltaTime)
    }

    /// The model's animation player, made on first use: it poses through ``pose`` and hands
    /// the rest of what the animations set to the entities drawing it.
    private func animationPlayer() throws -> GLTFAnimationPlayer {
        if let activeAnimationPlayer { return activeAnimationPlayer }
        guard let pose else {
            throw VRMError._notSupported("this entity has no pose to animate")
        }
        let player = GLTFAnimationPlayer(pose: pose)
        player.didApply = { [unowned self] output in
            MainActor.assumeIsolated { applyAnimationOutput(output) }
        }
        player.didSeek = { [unowned self] in
            MainActor.assumeIsolated { flushDeformation() }
        }
        player.didFinish = { [unowned self] in
            MainActor.assumeIsolated { components.remove(GLTFAnimationPlaybackComponent.self) }
        }
        activeAnimationPlayer = player
        return player
    }

    /// Hands what the animations set beyond the pose to what draws it.
    func applyAnimationOutput(_ output: GLTFAnimationOutput) {
        for (nodeIndex, weights) in output.morphWeights {
            for modelEntity in morphBindings[nodeIndex]?.modelEntities ?? [] {
                modelEntity.deformedMesh?.setBlendShapeWeights(weights)
            }
        }
    }

    private func animationRuntime(at index: Int) throws -> GLTFAnimationRuntime {
        if let cached = animationRuntimes[index] { return cached }
        let animation = try gltf.load(\.animations, at: index)
        let runtime = try GLTFAnimationRuntime(animation: animation,
                                               decoder: animationDecoder,
                                               posedNodes: Set(gltf.nodes.indices.filter { entity(forNodeAt: $0) != nil }),
                                               morphTargetCounts: morphBindings.compactMapValues {
                                                   $0.modelEntities.isEmpty ? nil : $0.targetCount
                                               })
        animationRuntimes[index] = runtime
        return runtime
    }
}
#endif
