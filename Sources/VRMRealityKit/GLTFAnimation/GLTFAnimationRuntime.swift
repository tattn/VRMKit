#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit

/// Decodes animation accessors into typed keyframe values, off a cache because
/// exporters routinely share one input accessor across many samplers.
final class GLTFAnimationDecoder {
    private let accessors: PackedAccessorCache
    private let nodes: [GLTF.Node]
    private var inputTimes: [Int: [Float]] = [:]

    init(document: GLTFDocument) {
        accessors = PackedAccessorCache(document: document)
        nodes = document.gltf.nodes ?? []
    }

    /// A sampler input. The spec fixes it to FLOAT scalars that start at or after
    /// zero and increase strictly, and ``GLTFKeyframeTrack`` reads that ordering
    /// as given.
    func times(at accessorIndex: Int) throws -> [Float] {
        if let cached = inputTimes[accessorIndex] { return cached }
        let accessor = try accessors.accessor(at: accessorIndex)
        guard accessor.componentType == .float else {
            throw VRMError._dataInconsistent(
                "an animation sampler input must be a FLOAT accessor, got \(accessor.componentType)"
            )
        }
        let times = try accessor.floatComponents(.SCALAR)
        guard times.first.map({ $0 >= 0 }) != false else {
            throw VRMError._dataInconsistent("animation sampler input times must start at or after 0")
        }
        inputTimes[accessorIndex] = times
        return times
    }

    /// Morph target weights. Like rotations they are unit quantities, so the spec
    /// also allows them in normalized integer storage.
    func weights(at accessorIndex: Int) throws -> [Float] {
        try output(at: accessorIndex, type: .SCALAR, allowsNormalizedIntegers: true)
    }

    func vector3s(at accessorIndex: Int) throws -> [SIMD3<Float>] {
        let floats = try output(at: accessorIndex, type: .VEC3, allowsNormalizedIntegers: false)
        return stride(from: 0, to: floats.count - floats.count % 3, by: 3).map {
            SIMD3<Float>(floats[$0], floats[$0 + 1], floats[$0 + 2])
        }
    }

    /// Rotation output as quaternions. Only the keyframe *values* are unit
    /// quaternions: a CUBICSPLINE output's tangents carry their slope in the length.
    func quaternions(at accessorIndex: Int,
                     interpolation: GLTF.Animation.Sampler.Interpolation) throws -> [simd_quatf] {
        let floats = try output(at: accessorIndex, type: .VEC4, allowsNormalizedIntegers: true)
        let isSpline = interpolation == .CUBICSPLINE
        return stride(from: 0, to: floats.count - floats.count % 4, by: 4).enumerated().map { element, offset in
            let vector = SIMD4<Float>(floats[offset], floats[offset + 1], floats[offset + 2], floats[offset + 3])
            let quaternion = simd_quatf(vector: vector)
            // Values only: normalized-integer storage rounds, so renormalize.
            guard !isSpline || element % 3 == 1 else { return quaternion }
            return quaternion.safelyNormalized
        }
    }

    /// A sampler output. Translations and scales are FLOAT-only; rotations and
    /// weights may also arrive as the normalized bytes and shorts the spec
    /// permits, which ``PackedAccessor`` decodes back to floats. UNSIGNED_INT is
    /// never one of them: the spec keeps it for primitive indices.
    private func output(at accessorIndex: Int,
                        type: GLTF.Accessor.`Type`,
                        allowsNormalizedIntegers: Bool) throws -> [Float] {
        let accessor = try accessors.accessor(at: accessorIndex)
        let isValid: Bool
        switch accessor.componentType {
        case .float:
            isValid = true
        case .byte, .unsignedByte, .short, .unsignedShort:
            isValid = allowsNormalizedIntegers && accessor.normalized
        case .unsignedInt:
            isValid = false
        }
        guard isValid else {
            throw VRMError._dataInconsistent(
                "this animation sampler output must be a FLOAT\(allowsNormalizedIntegers ? " or normalized byte / short" : "") accessor, got \(accessor.normalized ? "normalized " : "")\(accessor.componentType)"
            )
        }
        return try accessor.floatComponents(type)
    }

    struct Channel {
        let nodeIndex: Int
        let path: GLTF.Animation.Channel.Target.TargetPath
        let sampler: GLTF.Animation.Sampler
    }

    /// The animation's channels, checked against the rules the spec puts on
    /// them. Channels without a node target or with an unknown (extension) path
    /// are dropped rather than rejected, as the spec prescribes.
    func validatedChannels(of animation: GLTF.Animation) throws -> [Channel] {
        struct TargetKey: Hashable {
            let node: Int
            let path: GLTF.Animation.Channel.Target.TargetPath
        }

        var drivenTargets: Set<TargetKey> = []
        return try animation.channels.compactMap { channel in
            guard let nodeIndex = channel.target.node,
                  let path = channel.target.targetPath else { return nil }
            guard nodes.indices.contains(nodeIndex) else {
                throw VRMError._dataInconsistent(
                    "an animation channel targets node \(nodeIndex) of \(nodes.count) nodes"
                )
            }
            // The spec keeps `matrix` off an animated node, whose channels
            // state the TRS they drive.
            guard nodes[nodeIndex]._matrix == nil else {
                throw VRMError._dataInconsistent(
                    "animated node \(nodeIndex) must use translation / rotation / scale instead of matrix"
                )
            }
            // At most one channel of an animation may drive a (node, path):
            // which of two wins would be arbitrary, so reject rather than pick.
            guard drivenTargets.insert(TargetKey(node: nodeIndex, path: path)).inserted else {
                throw VRMError._dataInconsistent(
                    "two channels of this animation drive the \(path.rawValue) of node \(nodeIndex)"
                )
            }
            guard animation.samplers.indices.contains(channel.sampler) else {
                throw VRMError._dataInconsistent(
                    "animation channel references sampler \(channel.sampler) of \(animation.samplers.count)"
                )
            }
            return Channel(nodeIndex: nodeIndex, path: path, sampler: animation.samplers[channel.sampler])
        }
    }

    /// The animation's length: the input accessors' spec-required `max` when
    /// present, decoded input times otherwise.
    func duration(of animation: GLTF.Animation) -> TimeInterval {
        var duration: Float = 0
        for sampler in animation.samplers {
            if let max = (try? accessors.accessor(at: sampler.input))?.accessor.max?.first {
                duration = Swift.max(duration, max)
            } else if let last = try? times(at: sampler.input).last {
                duration = Swift.max(duration, last)
            }
        }
        return TimeInterval(duration)
    }

    /// Groups a weights output into one `[Float]` per keyframe element, which the
    /// spec sizes by the morph target count of the mesh the channel drives.
    static func weightGroups(scalars: [Float], groupCount: Int, targetCount: Int) throws -> [[Float]] {
        guard targetCount > 0, scalars.count == groupCount * targetCount else {
            throw VRMError._dataInconsistent(
                "weights animation output holds \(scalars.count) values, not the \(groupCount) keyframe elements × \(targetCount) morph targets it drives"
            )
        }
        return (0..<groupCount).map { Array(scalars[$0 * targetCount..<($0 + 1) * targetCount]) }
    }
}

/// One glTF animation decoded and bound to the entities it drives.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
final class GLTFAnimationRuntime: GLTFAnimationApplying {
    /// Every transform channel of one node, so a node animated on more than one
    /// path takes a single `Transform` write per frame.
    private struct TransformBinding {
        let target: Entity
        var translation: GLTFKeyframeTrack<SIMD3<Float>>?
        var rotation: GLTFKeyframeTrack<simd_quatf>?
        var scale: GLTFKeyframeTrack<SIMD3<Float>>?
    }

    private struct WeightBinding {
        let modelEntities: [ModelEntity]
        let track: GLTFKeyframeTrack<[Float]>
    }

    private let transformBindings: [TransformBinding]
    private let weightBindings: [WeightBinding]

    @MainActor
    init(animation: GLTF.Animation, entity: GLTFEntity) throws {
        let decoder = entity.animationDecoder
        // Keyed by node index so all of a node's channels land in one binding.
        var transforms: [Int: TransformBinding] = [:]
        var weights: [WeightBinding] = []

        for channel in try decoder.validatedChannels(of: animation) {
            let times = try decoder.times(at: channel.sampler.input)

            if channel.path == .weights {
                guard let binding = entity.morphBindings[channel.nodeIndex], !binding.modelEntities.isEmpty else { continue }
                let scalars = try decoder.weights(at: channel.sampler.output)
                let perKeyframe = channel.sampler.interpolation == .CUBICSPLINE ? 3 : 1
                let groups = try GLTFAnimationDecoder.weightGroups(scalars: scalars,
                                                                   groupCount: times.count * perKeyframe,
                                                                   targetCount: binding.targetCount)
                weights.append(WeightBinding(modelEntities: binding.modelEntities,
                                             track: try .init(times: times,
                                                              interpolation: channel.sampler.interpolation,
                                                              values: groups)))
                continue
            }

            guard let target = entity.entity(forNodeAt: channel.nodeIndex) else { continue }
            var binding = transforms[channel.nodeIndex] ?? TransformBinding(target: target)
            switch channel.path {
            case .translation:
                binding.translation = try .init(times: times,
                                                interpolation: channel.sampler.interpolation,
                                                values: decoder.vector3s(at: channel.sampler.output))
            case .rotation:
                binding.rotation = try .init(times: times,
                                             interpolation: channel.sampler.interpolation,
                                             values: decoder.quaternions(at: channel.sampler.output,
                                                                         interpolation: channel.sampler.interpolation))
            case .scale:
                binding.scale = try .init(times: times,
                                          interpolation: channel.sampler.interpolation,
                                          values: decoder.vector3s(at: channel.sampler.output))
            case .weights:
                break // handled above
            }
            transforms[channel.nodeIndex] = binding
        }

        transformBindings = Array(transforms.values)
        weightBindings = weights
    }

    /// Poses the bound entities for `time`.
    ///
    /// - Returns: whether any node transform actually changed, so the caller can
    ///   skip re-solving skin poses for a held pose.
    @MainActor
    @discardableResult
    func apply(at time: Float) -> Bool {
        var movedTransforms = false
        for binding in transformBindings {
            // The current transform is the base, so paths this animation does not
            // drive keep whatever else wrote them.
            let current = binding.target.transform
            var transform = current
            if let value = binding.translation?.value(at: time) { transform.translation = value }
            if let value = binding.rotation?.value(at: time) { transform.rotation = value }
            if let value = binding.scale?.value(at: time) { transform.scale = value }
            // Assigning `Entity.transform` invalidates the subtree's cached world
            // transforms, so a held pose must not write at all.
            guard transform != current else { continue }
            binding.target.transform = transform
            movedTransforms = true
        }
        for binding in weightBindings {
            let weights = binding.track.value(at: time)
            for modelEntity in binding.modelEntities {
                modelEntity.applyMorphWeights(weights)
            }
        }
        return movedTransforms
    }
}
#endif
