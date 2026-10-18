import Foundation
import simd
import VRMKit

package typealias ExpressionMaterialColorType = VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType

/// A material colour one expression drives, named by its glTF material index.
package struct ExpressionMaterialColorBinding {
    package let material: Int
    package let type: ExpressionMaterialColorType
    package let targetValue: SIMD4<Float>
    /// What the material was loaded with, which the expression moves away from
    /// and every inactive expression puts back.
    package let baseValue: SIMD4<Float>

    package init(material: Int,
                 type: ExpressionMaterialColorType,
                 targetValue: SIMD4<Float>,
                 baseValue: SIMD4<Float>) {
        self.material = material
        self.type = type
        self.targetValue = targetValue
        self.baseValue = baseValue
    }
}

/// A texture transform one expression drives. The rotation is not part of the
/// bind, so it rides along unchanged from the value the material was loaded with.
package struct ExpressionTextureTransformBinding {
    package let material: Int
    package let baseScale: SIMD2<Float>
    package let baseOffset: SIMD2<Float>
    package let baseRotation: Float
    package let targetScale: SIMD2<Float>
    package let targetOffset: SIMD2<Float>

    package init(material: Int,
                 baseScale: SIMD2<Float>,
                 baseOffset: SIMD2<Float>,
                 baseRotation: Float,
                 targetScale: SIMD2<Float>,
                 targetOffset: SIMD2<Float>) {
        self.material = material
        self.baseScale = baseScale
        self.baseOffset = baseOffset
        self.baseRotation = baseRotation
        self.targetScale = targetScale
        self.targetOffset = targetOffset
    }
}

/// How an ``ExpressionRuntime`` writes what it accumulated into the renderer,
/// which is the one part of driving expressions the runtime leaves to it.
package struct ExpressionApplier<Mesh: AnyObject> {
    package let setMorphWeight: (_ weight: Float, _ targetIndex: Int, _ mesh: Mesh) -> Void
    package let setMaterialColor: (_ color: SIMD4<Float>, _ type: ExpressionMaterialColorType, _ material: Int) -> Void
    package let setTextureTransform: (_ scale: SIMD2<Float>, _ offset: SIMD2<Float>, _ rotation: Float, _ material: Int) -> Void
    /// Called once per apply that wrote anything, for a renderer with a flush.
    package let didApply: () -> Void

    package init(setMorphWeight: @escaping (Float, Int, Mesh) -> Void,
                 setMaterialColor: @escaping (SIMD4<Float>, ExpressionMaterialColorType, Int) -> Void,
                 setTextureTransform: @escaping (SIMD2<Float>, SIMD2<Float>, Float, Int) -> Void,
                 didApply: @escaping () -> Void = {}) {
        self.setMorphWeight = setMorphWeight
        self.setMaterialColor = setMaterialColor
        self.setTextureTransform = setTextureTransform
        self.didApply = didApply
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

/// What applying needs of one expression besides its clip, held outside the generic
/// runtime so the per-frame loop touches no type generic over the mesh. Targets are
/// indices into the runtime's target lists.
private struct ExpressionSlot {
    let overrideGroup: ExpressionOverrideGroup?
    let isBinary: Bool
    var morphs: [(target: Int, weight: Float)] = []
    var colors: [(target: Int, delta: SIMD4<Float>)] = []
    var transforms: [(target: Int, scaleDelta: SIMD2<Float>, offsetDelta: SIMD2<Float>)] = []
}

/// The renderer-agnostic expression runtime: the clips a model states, the input
/// weights a caller sets, and the accumulation VRM defines over them, ending in
/// per-target values an ``ExpressionApplier`` writes out.
///
/// Weights accumulate rather than overwrite where expressions overlap on a target, an
/// active expression may suppress the blink / lookAt / mouth groups, and a value that did
/// not move since the last apply is not written again.
///
/// Keys and targets are resolved to indices once at set-up: a face tracker hands over
/// dozens of weights every frame, and hashing their keys and targets each time cost
/// more than the accumulation itself.
package final class ExpressionRuntime<Mesh: AnyObject> {
    package private(set) var clips: [ExpressionKey: ExpressionClip<Mesh>] = [:]
    /// The expressions the model offers, in the order the plan states them.
    package private(set) var availableExpressions: [ExpressionInfo] = []

    /// One per expression, in the order of `availableExpressions`.
    private var slots: [ExpressionSlot] = []
    private var slotClips: [ExpressionClip<Mesh>] = []
    /// The slot each key drives. A custom key spelling a preset drives the preset,
    /// which is how VRM 0.x models predating the presets name theirs.
    private var slotsByKey: [ExpressionKey: Int] = [:]
    /// Input weight per slot, zero when inactive.
    private var weights: [Float] = []

    // Every target any clip drives, once each, so applying the active clips can put
    // every untouched target back where it started.
    private var morphTargets: [BlendShapeBinding<Mesh>] = []
    private var colorTargets: [ExpressionMaterialColorBinding] = []
    private var transformTargets: [ExpressionTextureTransformBinding] = []

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

    /// Hands the runtime everything the model states, replacing what it had.
    package func setUp(clips statedClips: [ExpressionClip<Mesh>],
                       materialColorClips: [ExpressionKey: [ExpressionMaterialColorBinding]],
                       textureTransformClips: [ExpressionKey: [ExpressionTextureTransformBinding]]) {
        // Two clips sharing a key is malformed; the later one wins, in the place the
        // first one took, so `clips` and `availableExpressions` stay the same set.
        var stated: [ExpressionClip<Mesh>] = []
        var positions: [ExpressionKey: Int] = [:]
        for clip in statedClips {
            if let position = positions[clip.key] {
                stated[position] = clip
            } else {
                positions[clip.key] = stated.count
                stated.append(clip)
            }
        }
        clips = Dictionary(uniqueKeysWithValues: stated.map { ($0.key, $0) })
        availableExpressions = stated.map { ExpressionInfo(key: $0.key, name: $0.name) }
        slotClips = stated

        slotsByKey = positions
        for (key, slot) in positions {
            if case .preset(let preset) = key, positions[.custom(preset.rawValue)] == nil {
                slotsByKey[.custom(preset.rawValue)] = slot
            }
        }

        var morphTargetIndices: [ObjectIdentifier: [Int: Int]] = [:]
        var colorTargetIndices: [Int: [ExpressionMaterialColorType: Int]] = [:]
        var transformTargetIndices: [Int: Int] = [:]
        morphTargets = []
        colorTargets = []
        transformTargets = []
        slots = stated.map { clip in
            var slot = ExpressionSlot(overrideGroup: clip.key.overrideGroup, isBinary: clip.isBinary)
            for binding in clip.values {
                let mesh = ObjectIdentifier(binding.mesh)
                let target: Int
                if let existing = morphTargetIndices[mesh]?[binding.index] {
                    target = existing
                    morphTargets[target] = binding
                } else {
                    target = morphTargets.count
                    morphTargetIndices[mesh, default: [:]][binding.index] = target
                    morphTargets.append(binding)
                }
                slot.morphs.append((target, Float(binding.weight)))
            }
            for binding in materialColorClips[clip.key] ?? [] {
                let target: Int
                if let existing = colorTargetIndices[binding.material]?[binding.type] {
                    target = existing
                    colorTargets[target] = binding
                } else {
                    target = colorTargets.count
                    colorTargetIndices[binding.material, default: [:]][binding.type] = target
                    colorTargets.append(binding)
                }
                slot.colors.append((target, binding.targetValue - binding.baseValue))
            }
            for binding in textureTransformClips[clip.key] ?? [] {
                let target: Int
                if let existing = transformTargetIndices[binding.material] {
                    target = existing
                    transformTargets[target] = binding
                } else {
                    target = transformTargets.count
                    transformTargetIndices[binding.material] = target
                    transformTargets.append(binding)
                }
                slot.transforms.append((target,
                                        binding.targetScale - binding.baseScale,
                                        binding.targetOffset - binding.baseOffset))
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

    /// Hands the runtime what the model states, resolving each bind to the renderer's
    /// own meshes and materials. A bind that will not resolve is left out.
    package func setUp(plan: VRMExpressionPlan,
                       morphBindings: (VRMExpressionPlan.MorphBind) -> [BlendShapeBinding<Mesh>],
                       materialColorBinding: (String, VRMExpressionPlan.MaterialColorBind) -> ExpressionMaterialColorBinding?,
                       textureTransformBinding: (String, VRMExpressionPlan.TextureTransformBind) -> ExpressionTextureTransformBinding?) {
        var clips: [ExpressionClip<Mesh>] = []
        var materialColorClips: [ExpressionKey: [ExpressionMaterialColorBinding]] = [:]
        var textureTransformClips: [ExpressionKey: [ExpressionTextureTransformBinding]] = [:]

        for planned in plan.clips {
            let clip = ExpressionClip(name: planned.name,
                                      preset: planned.preset,
                                      values: planned.morphBinds.flatMap(morphBindings),
                                      isBinary: planned.isBinary,
                                      binaryRounding: planned.binaryRounding,
                                      overrideBlink: planned.overrideBlink,
                                      overrideLookAt: planned.overrideLookAt,
                                      overrideMouth: planned.overrideMouth)
            clips.append(clip)

            let colors = planned.materialColorBinds.compactMap { materialColorBinding(planned.name, $0) }
            if !colors.isEmpty {
                materialColorClips[clip.key] = colors
            }
            let transforms = planned.textureTransformBinds.compactMap { textureTransformBinding(planned.name, $0) }
            if !transforms.isEmpty {
                textureTransformClips[clip.key] = transforms
            }
        }

        setUp(clips: clips,
              materialColorClips: materialColorClips,
              textureTransformClips: textureTransformClips)
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
            let weight = Float(slotClips[slot].normalizedWeight(Double(values.values[slot])))
            guard weight != weights[slot] else { continue }
            weights[slot] = weight
            changed = true
        }
        return changed
    }

    /// The input weight `key` was last set to, before any override scales it.
    package func weight(for key: ExpressionKey) -> Double {
        guard let slot = slotsByKey[key] else { return 0 }
        return Double(weights[slot])
    }

    /// Records input weights, reporting whether any actually moved: nothing has
    /// to be applied when none did.
    package func storeWeights<Value: BinaryFloatingPoint>(_ values: [ExpressionKey: Value]) -> Bool {
        var changed = false
        for (key, value) in values {
            guard let slot = slotsByKey[key] else { continue }
            let weight = Float(slotClips[slot].normalizedWeight(Double(value)))
            guard weight != weights[slot] else { continue }
            weights[slot] = weight
            changed = true
        }
        return changed
    }

    /// Accumulates every active expression and writes what moved through
    /// `applier`.
    package func apply(with applier: ExpressionApplier<Mesh>) {
        var overrides = ExpressionOverrideStates()
        for (slot, weight) in weights.enumerated() where weight > 0 {
            overrides.accumulate(slotClips[slot], weight: Double(weight), excluding: slots[slot].overrideGroup)
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
                weight = slot.isBinary ? 0 : weight * Float(overrides[group].factor)
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

        var wroteAnything = false
        for (target, weight) in scratchMorphWeights.enumerated() where appliedMorphWeights[target] != weight {
            appliedMorphWeights[target] = weight
            wroteAnything = true
            let binding = morphTargets[target]
            applier.setMorphWeight(weight, binding.index, binding.mesh)
        }
        for (target, color) in scratchColors.enumerated() where appliedColors[target] != color {
            appliedColors[target] = color
            wroteAnything = true
            let binding = colorTargets[target]
            applier.setMaterialColor(color, binding.type, binding.material)
        }
        for target in transformTargets.indices {
            let scale = scratchScales[target]
            let offset = scratchOffsets[target]
            let applied = SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)
            guard appliedTransforms[target] != applied else { continue }
            appliedTransforms[target] = applied
            wroteAnything = true
            let binding = transformTargets[target]
            applier.setTextureTransform(scale, offset, binding.baseRotation, binding.material)
        }

        if wroteAnything {
            applier.didApply()
        }
    }
}
