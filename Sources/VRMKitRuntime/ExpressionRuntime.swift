#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat
import VRMKit

package typealias ExpressionMaterialColorType = VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType

/// How an ``ExpressionRuntime`` writes out what it accumulated, which is the one part
/// of driving expressions it leaves to the model.
package struct ExpressionApplier {
    package let setMorphWeight: (_ weight: Float, _ targetIndex: Int, _ node: Int) -> Void
    package let setMaterialColor: (_ color: SIMD4<Float>, _ type: ExpressionMaterialColorType, _ material: Int) -> Void
    package let setTextureTransform: (_ scale: SIMD2<Float>, _ offset: SIMD2<Float>, _ rotation: Float, _ material: Int) -> Void

    package init(setMorphWeight: @escaping (Float, Int, Int) -> Void,
                 setMaterialColor: @escaping (SIMD4<Float>, ExpressionMaterialColorType, Int) -> Void,
                 setTextureTransform: @escaping (SIMD2<Float>, SIMD2<Float>, Float, Int) -> Void) {
        self.setMorphWeight = setMorphWeight
        self.setMaterialColor = setMaterialColor
        self.setTextureTransform = setTextureTransform
    }
}

/// One expression of one loaded model, looked up once with its key so that setting weights
/// every frame hashes nothing (``ExpressionWeights``).
public struct ExpressionHandle: Hashable, Sendable {
    package let slot: Int
}

/// Expression weights set by ``ExpressionHandle``, the input a face tracker or other per-frame
/// driver hands a model in one go. Only the weights set since the last ``reset()`` are applied;
/// the other expressions keep what they had, such as what the model's gaze sets. Weights clamp to
/// 0...1 when applied.
public struct ExpressionWeights: Equatable, Sendable {
    package private(set) var values: [Float]
    private var isSet: [Bool]
    package private(set) var setSlots: [Int] = []

    package init(count: Int) {
        values = Array(repeating: 0, count: count)
        isSet = Array(repeating: false, count: count)
    }

    public subscript(handle: ExpressionHandle) -> Float {
        get { values[handle.slot] }
        set {
            values[handle.slot] = newValue
            if !isSet[handle.slot] {
                isSet[handle.slot] = true
                setSlots.append(handle.slot)
            }
        }
    }

    /// Forgets every weight set, so the next apply changes nothing until one is set again.
    public mutating func reset() {
        for slot in setSlots {
            values[slot] = 0
            isSet[slot] = false
        }
        setSlots.removeAll(keepingCapacity: true)
    }
}

/// What applying needs of one expression besides its clip. Targets are indices into the
/// runtime's target lists.
private struct ExpressionSlot {
    let overrideGroup: ExpressionOverrideGroup?
    let isBinary: Bool
    var morphs: [(target: Int, weight: Float)] = []
    var colors: [(target: Int, delta: SIMD4<Float>)] = []
    var transforms: [(target: Int, scaleDelta: SIMD2<Float>, offsetDelta: SIMD2<Float>)] = []
}

/// A morph target of the mesh a node draws.
private struct MorphTarget {
    let node: Int
    let index: Int
}

/// A material colour, with what the material was loaded with, which an expression
/// moves away from and every inactive expression puts back.
private struct ColorTarget {
    let material: Int
    let type: ExpressionMaterialColorType
    let baseValue: SIMD4<Float>
}

/// A material's UV transform as loaded. The rotation is not part of a bind, so it
/// rides along unchanged.
private struct TransformTarget {
    let material: Int
    let baseScale: SIMD2<Float>
    let baseOffset: SIMD2<Float>
    let baseRotation: Float
}

/// The expression runtime: the clips a model states, the input weights a caller sets,
/// and the accumulation VRM defines over them, ending in per-target values an
/// ``ExpressionApplier`` writes out.
///
/// Weights accumulate rather than overwrite where expressions overlap on a target, an
/// active expression may suppress the blink / lookAt / mouth groups, and a value that did
/// not move since the last apply is not written again.
///
/// Keys and targets are resolved to indices once at set-up: a face tracker hands over
/// dozens of weights every frame, and hashing their keys and targets each time cost
/// more than the accumulation itself.
package final class ExpressionRuntime {
    /// The expressions the model offers, in the order it states them.
    package private(set) var availableExpressions: [ExpressionInfo] = []

    /// One per expression, in the order of `availableExpressions`.
    private var slots: [ExpressionSlot] = []
    private var slotClips: [VRMExpressionClip] = []
    /// The slot each key drives. A custom key spelling a preset drives the preset,
    /// which is how VRM 0.x models predating the presets name theirs.
    private var slotsByKey: [ExpressionKey: Int] = [:]
    /// Input weight per slot, zero when inactive.
    private var weights: [Float] = []

    // Every target any clip drives, once each, so applying the active clips can put
    // every untouched target back where it started.
    private var morphTargets: [MorphTarget] = []
    private var colorTargets: [ColorTarget] = []
    private var transformTargets: [TransformTarget] = []

    // Values last written out, nil until the first write, so a value that did not move
    // is not written again.
    private var appliedMorphWeights: [Float?] = []
    private var appliedColors: [SIMD4<Float>?] = []
    private var appliedTransforms: [SIMD4<Float>?] = []

    // Scratch for one apply, held so that driving expressions every frame allocates
    // nothing.
    private var scratchMorphWeights: [Float] = []
    private var scratchColors: [SIMD4<Float>] = []
    private var scratchScales: [SIMD2<Float>] = []
    private var scratchOffsets: [SIMD2<Float>] = []

    package init() {}

    /// Hands the runtime the clips the model states, replacing what it had. `morphNodes`
    /// names the nodes whose mesh a morph bind drives, and `baseColor` and `baseUVTransform`
    /// what a material draws with before any expression moves it. A bind that will not
    /// resolve is left out.
    package func setUp(clips statedClips: [VRMExpressionClip],
                       morphNodes: (VRMExpressionClip.MorphBind.Target) -> [Int],
                       baseColor: (Int, ExpressionMaterialColorType) -> SIMD4<Float>?,
                       baseUVTransform: (Int) -> (scale: SIMD2<Float>, offset: SIMD2<Float>, rotation: Float)?) {
        // Two clips sharing a key is malformed; the later one wins, in the place the
        // first one took.
        var stated: [VRMExpressionClip] = []
        var positions: [ExpressionKey: Int] = [:]
        for clip in statedClips {
            if let position = positions[clip.key] {
                stated[position] = clip
            } else {
                positions[clip.key] = stated.count
                stated.append(clip)
            }
        }
        availableExpressions = stated.map { ExpressionInfo(key: $0.key, name: $0.name) }
        slotClips = stated

        slotsByKey = positions
        for (key, slot) in positions {
            if case .preset(let preset) = key, positions[.custom(preset.rawValue)] == nil {
                slotsByKey[.custom(preset.rawValue)] = slot
            }
        }

        var morphTargetIndices: [Int: [Int: Int]] = [:]
        var colorTargetIndices: [Int: [ExpressionMaterialColorType: Int]] = [:]
        var transformTargetIndices: [Int: Int] = [:]
        morphTargets = []
        colorTargets = []
        transformTargets = []
        slots = stated.map { clip in
            var slot = ExpressionSlot(overrideGroup: clip.key.overrideGroup, isBinary: clip.isBinary)
            for bind in clip.morphBinds {
                for node in morphNodes(bind.target) {
                    let target: Int
                    if let existing = morphTargetIndices[node]?[bind.index] {
                        target = existing
                    } else {
                        target = morphTargets.count
                        morphTargetIndices[node, default: [:]][bind.index] = target
                        morphTargets.append(MorphTarget(node: node, index: bind.index))
                    }
                    slot.morphs.append((target, bind.weight))
                }
            }
            for bind in clip.materialColorBinds {
                let target: Int
                if let existing = colorTargetIndices[bind.material]?[bind.type] {
                    target = existing
                } else if let baseValue = baseColor(bind.material, bind.type) {
                    target = colorTargets.count
                    colorTargetIndices[bind.material, default: [:]][bind.type] = target
                    colorTargets.append(ColorTarget(material: bind.material, type: bind.type, baseValue: baseValue))
                } else {
                    continue
                }
                slot.colors.append((target, bind.targetValue - colorTargets[target].baseValue))
            }
            for bind in clip.textureTransformBinds {
                let target: Int
                if let existing = transformTargetIndices[bind.material] {
                    target = existing
                } else if let base = baseUVTransform(bind.material) {
                    target = transformTargets.count
                    transformTargetIndices[bind.material] = target
                    transformTargets.append(TransformTarget(material: bind.material,
                                                            baseScale: base.scale,
                                                            baseOffset: base.offset,
                                                            baseRotation: base.rotation))
                } else {
                    continue
                }
                slot.transforms.append((target,
                                        bind.scale - transformTargets[target].baseScale,
                                        bind.offset - transformTargets[target].baseOffset))
            }
            return slot
        }

        weights = Array(repeating: 0, count: slots.count)
        appliedMorphWeights = Array(repeating: nil, count: morphTargets.count)
        appliedColors = Array(repeating: nil, count: colorTargets.count)
        appliedTransforms = Array(repeating: nil, count: transformTargets.count)
        scratchMorphWeights = Array(repeating: 0, count: morphTargets.count)
        scratchColors = colorTargets.map(\.baseValue)
        scratchScales = transformTargets.map(\.baseScale)
        scratchOffsets = transformTargets.map(\.baseOffset)
    }

    /// The handle `key` drives, a custom key spelling a preset driving the preset.
    package func handle(for key: ExpressionKey) -> ExpressionHandle? {
        slotsByKey[key].map(ExpressionHandle.init(slot:))
    }

    package var expressionCount: Int { slots.count }

    /// Records the input weights `values` sets, reporting whether any moved.
    package func storeWeights(_ values: ExpressionWeights) -> Bool {
        guard values.values.count == weights.count else { return false }
        var changed = false
        for slot in values.setSlots {
            let weight = slotClips[slot].normalizedWeight(values.values[slot])
            guard weight != weights[slot] else { continue }
            weights[slot] = weight
            changed = true
        }
        return changed
    }

    /// The input weight `key` was last set to, before any override scales it.
    package func weight(for key: ExpressionKey) -> Float {
        guard let slot = slotsByKey[key] else { return 0 }
        return weights[slot]
    }

    /// Records input weights, reporting whether any actually moved: nothing has
    /// to be applied when none did.
    package func storeWeights(_ values: [ExpressionKey: Float]) -> Bool {
        var changed = false
        for (key, value) in values {
            guard let slot = slotsByKey[key] else { continue }
            let weight = slotClips[slot].normalizedWeight(value)
            guard weight != weights[slot] else { continue }
            weights[slot] = weight
            changed = true
        }
        return changed
    }

    /// Accumulates every active expression and writes what moved through
    /// `applier`.
    package func apply(with applier: ExpressionApplier) {
        var overrides = ExpressionOverrideStates()
        for (slot, weight) in weights.enumerated() where weight > 0 {
            overrides.accumulate(slotClips[slot], weight: weight, excluding: slots[slot].overrideGroup)
        }
        let overridesAny = overrides.isSuppressingAnyGroup

        for target in scratchMorphWeights.indices {
            scratchMorphWeights[target] = 0
        }
        for target in colorTargets.indices {
            scratchColors[target] = colorTargets[target].baseValue
        }
        for target in transformTargets.indices {
            scratchScales[target] = transformTargets[target].baseScale
            scratchOffsets[target] = transformTargets[target].baseOffset
        }

        for (index, slot) in slots.enumerated() {
            var weight = weights[index]
            guard weight > 0 else { continue }
            // An overridden binary expression is suppressed outright rather than scaled,
            // having no partial state.
            if overridesAny, let group = slot.overrideGroup, overrides[group].isSuppressing {
                weight = slot.isBinary ? 0 : weight * overrides[group].factor
                guard weight > 0 else { continue }
            }
            for morph in slot.morphs {
                scratchMorphWeights[morph.target] += morph.weight * weight
            }
            for color in slot.colors {
                scratchColors[color.target] += color.delta * weight
            }
            for transform in slot.transforms {
                scratchScales[transform.target] += transform.scaleDelta * weight
                scratchOffsets[transform.target] += transform.offsetDelta * weight
            }
        }

        for (target, weight) in scratchMorphWeights.enumerated() where appliedMorphWeights[target] != weight {
            appliedMorphWeights[target] = weight
            let morph = morphTargets[target]
            applier.setMorphWeight(weight, morph.index, morph.node)
        }
        for (target, color) in scratchColors.enumerated() where appliedColors[target] != color {
            appliedColors[target] = color
            let binding = colorTargets[target]
            applier.setMaterialColor(color, binding.type, binding.material)
        }
        for target in transformTargets.indices {
            let scale = scratchScales[target]
            let offset = scratchOffsets[target]
            let applied = SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)
            guard appliedTransforms[target] != applied else { continue }
            appliedTransforms[target] = applied
            let binding = transformTargets[target]
            applier.setTextureTransform(scale, offset, binding.baseRotation, binding.material)
        }
    }
}
