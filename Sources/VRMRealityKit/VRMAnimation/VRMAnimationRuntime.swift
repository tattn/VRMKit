#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

/// One VRM animation (`VRMC_vrm_animation`) decoded and retargeted onto the
/// humanoid bones and expressions of a ``VRMEntity``.
///
/// The spec rests both skeletons in T-pose, so a bone's animated local rotation
/// carries over after re-expressing it between the two rest orientations, and
/// the hips translation scales by the rest hips-height ratio. A VRM 0.x model
/// faces the other way than the VRM 1.0 convention `.vrma` files are authored
/// in, so for one the whole animation is turned 180° around Y as well.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class VRMAnimationRuntime {
    /// Every retargeted channel of one animation node, so a bone animated on
    /// rotation and translation takes a single `Transform` write per frame.
    private struct BoneBinding {
        let target: Entity
        var rotation: RotationChannel?
        var translation: TranslationChannel?
    }

    /// One source rotation channel re-expressed as the world-space rotation its
    /// bone adds to its parent's, which is identity while the animation rests.
    private struct RotationDelta {
        let track: GLTFKeyframeTrack<simd_quatf>
        /// (animation parent rest world), with the VRM 0.x facing flip folded in.
        let pre: simd_quatf
        /// inverse(animation node rest world), flip folded in.
        let post: simd_quatf

        func value(at time: Float) -> simd_quatf {
            pre * track.value(at: time) * post
        }
    }

    private struct RotationChannel {
        /// The deltas of the source bones between this one and the nearest
        /// ancestor the target model also has, root first, with this bone's own
        /// last, so a bone the model lacks still passes its rotation down.
        let deltas: [RotationDelta]
        /// inverse(target parent rest world).
        let pre: simd_quatf
        /// target node rest world.
        let post: simd_quatf

        func value(at time: Float) -> simd_quatf {
            deltas.reduce(pre) { $0 * $1.value(at: time) } * post
        }
    }

    private struct TranslationChannel {
        let track: GLTFKeyframeTrack<SIMD3<Float>>
        /// Takes the animation-local translation through its parent's rest
        /// transform into model space, turns and scales it there, then down into
        /// the target parent's: a bone's parents need not rest untransformed.
        let transform: simd_float4x4

        func value(at time: Float) -> SIMD3<Float> {
            transform.multiplyPoint(track.value(at: time))
        }
    }

    private struct ExpressionBinding {
        /// Every expression the node's weight drives, sampled once for all.
        let keys: [ExpressionKey]
        let track: GLTFKeyframeTrack<SIMD3<Float>>
    }

    /// Weak, so the runtime does not keep the model it poses alive.
    private weak var entity: VRMEntity?
    private let boneBindings: [BoneBinding]
    private let expressionBindings: [ExpressionBinding]

    /// Metadata the playback controller shows.
    let name: String?
    let duration: TimeInterval

    init(animation vrmAnimation: VRMAnimation, animationIndex: Int, entity: VRMEntity) throws {
        self.entity = entity
        let gltf = vrmAnimation.document.gltf
        let animation = try gltf.load(\.animations, at: animationIndex)
        let decoder = GLTFAnimationDecoder(document: vrmAnimation.document)

        let isVRM0Target = if case .v0 = entity.vrm { true } else { false }
        // Turning the animation's world by 180° around Y conjugates rotations
        // and rotates translations; identity leaves both formulas untouched.
        let flip = isVRM0Target ? simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)) : quat_identity_float

        // The animation's document has nowhere to cache one; the model's does.
        let animationRest = try GLTFRestPose(nodes: gltf.nodes ?? [])
        let targetRest = try entity.restPose()

        var boneByNode: [Int: HumanoidBone] = [:]
        for (name, humanBone) in vrmAnimation.humanoid?.humanBones ?? [:] {
            guard let bone = Self.targetBone(named: name) else { continue }
            boneByNode[humanBone.node] = bone
        }
        // Node → the expressions its weight drives. Nothing keeps two of them
        // off one node, and dropping either of the two would be arbitrary.
        var expressionKeysByNode: [Int: [ExpressionKey]] = [:]
        if let expressions = vrmAnimation.expressions {
            for (name, expression) in expressions.preset ?? [:] {
                guard let preset = ExpressionPreset(name: name),
                      !Self.lookAtPresets.contains(preset) else { continue }
                expressionKeysByNode[expression.node, default: []].append(.preset(preset))
            }
            for (name, expression) in expressions.custom ?? [:] {
                expressionKeysByNode[expression.node, default: []].append(.custom(name))
            }
        }

        /// Resolved through the entity, so the rest lookups and the transform
        /// writes address the same node.
        func targetNode(for bone: HumanoidBone) -> (entity: Entity, nodeIndex: Int)? {
            guard let target = entity.humanoid.node(for: bone),
                  let nodeIndex = target.components[GLTFNodeComponent.self]?.nodeIndex else { return nil }
            return (target, nodeIndex)
        }

        var hipsScale: Float = 1
        if let animationHips = vrmAnimation.humanoid?.humanBones[HumanoidBone.hips.rawValue]?.node,
           let targetHips = targetNode(for: .hips) {
            let animationHeight = animationRest.worldPosition(at: animationHips).y
            let targetHeight = targetRest.worldPosition(at: targetHips.nodeIndex).y
            if animationHeight > .ulpOfOne, targetHeight > .ulpOfOne {
                hipsScale = targetHeight / animationHeight
            }
        }
        // What the hips motion takes in model space, between the two skeletons:
        // the VRM 0.x facing flip, and the rest hips-height ratio.
        let modelTransform = simd_float4x4(flip) * simd_float4x4(diagonal: SIMD4(hipsScale, hipsScale, hipsScale, 1))

        // Decoded first and bound afterwards: a bone the target model lacks
        // hands its rotation to descendants whose channels may come in any
        // order, so every track has to be in hand before the bindings are built.
        var rotationTracks: [Int: GLTFKeyframeTrack<simd_quatf>] = [:]
        var translationTracks: [Int: GLTFKeyframeTrack<SIMD3<Float>>] = [:]
        var expressions: [ExpressionBinding] = []

        for channel in try decoder.validatedChannels(of: animation) {
            let times = try decoder.times(at: channel.sampler.input)

            if let keys = expressionKeysByNode[channel.nodeIndex] {
                // The expression weight rides on the node's translation X.
                guard channel.path == .translation else { continue }
                expressions.append(ExpressionBinding(keys: keys,
                                                     track: try .init(times: times,
                                                                      interpolation: channel.sampler.interpolation,
                                                                      values: decoder.vector3s(at: channel.sampler.output))))
                continue
            }

            // Channels of nodes mapped to nothing retarget to nothing and are
            // skipped: look-at, and bones outside the VRM humanoid.
            guard animationRest.contains(channel.nodeIndex),
                  boneByNode[channel.nodeIndex] != nil else { continue }

            switch channel.path {
            case .rotation:
                rotationTracks[channel.nodeIndex] = try .init(
                    times: times,
                    interpolation: channel.sampler.interpolation,
                    values: decoder.quaternions(at: channel.sampler.output,
                                                interpolation: channel.sampler.interpolation))
            case .translation:
                translationTracks[channel.nodeIndex] = try .init(times: times,
                                                                 interpolation: channel.sampler.interpolation,
                                                                 values: decoder.vector3s(at: channel.sampler.output))
            case .scale, .weights:
                // The spec forbids scaling humanoid bones, and their meshes'
                // morph weights are the expressions' to drive.
                continue
            }
        }

        /// The world-space rotation a source bone adds to its parent's.
        func delta(at nodeIndex: Int) -> RotationDelta? {
            rotationTracks[nodeIndex].map {
                RotationDelta(track: $0,
                              pre: flip * animationRest.parentWorldRotation(at: nodeIndex),
                              post: animationRest.worldRotation(at: nodeIndex).inverse * flip.inverse)
            }
        }

        /// The source humanoid bones between `nodeIndex` and its nearest
        /// ancestor bone the target model also has, root first. The pose
        /// conversion guide has a target lacking an optional bone take its
        /// rotation through the descendants that replaced it: a source
        /// `upperChest` bend still reaches its neck and shoulders.
        func skippedAncestorDeltas(above nodeIndex: Int) -> [RotationDelta] {
            var deltas: [RotationDelta] = []
            var ancestor = animationRest.parent(at: nodeIndex)
            while let index = ancestor {
                if let bone = boneByNode[index] {
                    guard targetNode(for: bone) == nil else { break }
                    if let delta = delta(at: index) {
                        deltas.append(delta)
                    }
                }
                ancestor = animationRest.parent(at: index)
            }
            return deltas.reversed()
        }

        var bones: [BoneBinding] = []
        for (nodeIndex, bone) in boneByNode {
            guard animationRest.contains(nodeIndex), let target = targetNode(for: bone) else { continue }

            var deltas = skippedAncestorDeltas(above: nodeIndex)
            if let own = delta(at: nodeIndex) {
                deltas.append(own)
            }
            let rotation = deltas.isEmpty ? nil : RotationChannel(
                deltas: deltas,
                pre: targetRest.parentWorldRotation(at: target.nodeIndex).inverse,
                post: targetRest.worldRotation(at: target.nodeIndex))
            // The spec keeps every humanoid translation but the hips' out of a
            // `.vrma`; one that carries them anyway is not retargeted.
            let translation = (bone == .hips ? translationTracks[nodeIndex] : nil).map {
                TranslationChannel(track: $0,
                                   transform: targetRest.parentWorldMatrix(at: target.nodeIndex).inverse
                                       * modelTransform * animationRest.parentWorldMatrix(at: nodeIndex))
            }
            guard rotation != nil || translation != nil else { continue }
            bones.append(BoneBinding(target: target.entity, rotation: rotation, translation: translation))
        }

        boneBindings = bones
        expressionBindings = expressions

        self.name = animation.name
        self.duration = decoder.duration(of: animation)
    }

    /// The presets a `.vrma` may not carry: look-at aims the gaze instead.
    private static let lookAtPresets: Set<ExpressionPreset> = [.lookUp, .lookDown, .lookLeft, .lookRight]

    /// The target model's bone for a `.vrma` humanoid bone name, or nil for a
    /// name no bone of the model is to take. A `.vrma` is VRM 1.0, which is how
    /// ``HumanoidBone`` names its bones, so the two spellings already agree.
    private static func targetBone(named name: String) -> HumanoidBone? {
        switch HumanoidBone(rawValue: name) {
        // Gaze is look-at's to aim, so the eyes take no bone animation.
        case .leftEye, .rightEye: nil
        case let bone: bone
        }
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension VRMAnimationRuntime: GLTFAnimationApplying {
    /// Poses the bound bones and expressions for `time`.
    ///
    /// - Returns: whether any bone transform actually changed, so the caller
    ///   can skip re-solving skin poses for a held pose.
    @discardableResult
    func apply(at time: Float) -> Bool {
        var movedTransforms = false
        for binding in boneBindings {
            // The current transform is the base, so paths this animation does
            // not drive keep whatever else wrote them.
            let current = binding.target.transform
            var transform = current
            if let channel = binding.rotation {
                transform.rotation = channel.value(at: time)
            }
            if let channel = binding.translation {
                transform.translation = channel.value(at: time)
            }
            // Assigning `Entity.transform` invalidates the subtree's cached world
            // transforms, so a held pose must not write at all.
            guard transform != current else { continue }
            binding.target.transform = transform
            movedTransforms = true
        }

        applyExpressions(at: time)
        return movedTransforms
    }

    /// Sampled weights go to the entity in full every frame, without a cache of
    /// what this runtime last wrote: an animation started later must be able to
    /// take an expression over, and re-asserting a weight the entity already
    /// holds costs nothing there, as ``VRMEntity/setExpressions(_:)`` drops the
    /// ones that did not move.
    private func applyExpressions(at time: Float) {
        guard let entity, !expressionBindings.isEmpty else { return }
        var weights: [ExpressionKey: CGFloat] = [:]
        for binding in expressionBindings {
            let weight = CGFloat(min(max(binding.track.value(at: time).x, 0), 1))
            for key in binding.keys {
                weights[key] = weight
            }
        }
        // Sent together so the entity re-accumulates its bindings once.
        entity.setExpressions(weights)
    }
}
#endif
