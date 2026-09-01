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

/// The renderer-agnostic expression runtime: the clips a model states, the input
/// weights a caller sets, and the accumulation VRM defines over them, ending in
/// per-target values an ``ExpressionApplier`` writes out.
///
/// Weights accumulate rather than overwrite where expressions overlap on a target, an
/// active expression may suppress the blink / lookAt / mouth groups, and a value that did
/// not move since the last apply is not written again.
package final class ExpressionRuntime<Mesh: AnyObject> {
    package private(set) var clips: [ExpressionKey: ExpressionClip<Mesh>] = [:]
    /// The expressions the model offers, in the order the plan states them.
    package private(set) var availableExpressions: [ExpressionInfo] = []
    private var materialColorClips: [ExpressionKey: [ExpressionMaterialColorBinding]] = [:]
    private var textureTransformClips: [ExpressionKey: [ExpressionTextureTransformBinding]] = [:]

    /// Input weights per expression, zero entries left out.
    private var weights: [ExpressionKey: Float] = [:]

    private struct MorphKey: Hashable {
        let mesh: ObjectIdentifier
        let targetIndex: Int
    }

    private struct ColorKey: Hashable {
        let material: Int
        let type: ExpressionMaterialColorType
    }

    // Every binding any clip holds, indexed once at set-up, so applying the
    // active clips can put every untouched target back where it started.
    private var morphIndex: [MorphKey: BlendShapeBinding<Mesh>] = [:]
    private var colorIndex: [ColorKey: ExpressionMaterialColorBinding] = [:]
    private var transformIndex: [Int: ExpressionTextureTransformBinding] = [:]

    // Values last written out, so a value that did not move is not written again.
    private var appliedMorphWeights: [MorphKey: Float] = [:]
    private var appliedColors: [ColorKey: SIMD4<Float>] = [:]
    private var appliedTransforms: [Int: SIMD4<Float>] = [:]

    // Scratch for one apply, held so that driving expressions every frame
    // allocates nothing once the capacities settle.
    private var scratchMorphWeights: [MorphKey: Float] = [:]
    private var scratchColors: [ColorKey: SIMD4<Float>] = [:]
    private var scratchScales: [Int: SIMD2<Float>] = [:]
    private var scratchOffsets: [Int: SIMD2<Float>] = [:]

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
        self.materialColorClips = materialColorClips
        self.textureTransformClips = textureTransformClips
        weights = [:]
        morphIndex = [:]
        colorIndex = [:]
        transformIndex = [:]
        appliedMorphWeights = [:]
        appliedColors = [:]
        appliedTransforms = [:]
        for binding in clips.values.flatMap(\.values) {
            morphIndex[MorphKey(mesh: ObjectIdentifier(binding.mesh), targetIndex: binding.index)] = binding
        }
        for binding in materialColorClips.values.joined() {
            colorIndex[ColorKey(material: binding.material, type: binding.type)] = binding
        }
        for binding in textureTransformClips.values.joined() {
            transformIndex[binding.material] = binding
        }
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

    /// The key a clip is actually stored under. An expression named after a
    /// preset is that preset, which is how VRM 0.x models predating the presets
    /// name theirs.
    package func canonicalKey(for key: ExpressionKey) -> ExpressionKey? {
        clips.canonicalKey(for: key)
    }

    /// The input weight `key` was last set to, before any override scales it.
    package func weight(for key: ExpressionKey) -> Double {
        guard let key = canonicalKey(for: key) else { return 0 }
        return Double(weights[key] ?? 0)
    }

    /// Records input weights, reporting whether any actually moved: nothing has
    /// to be applied when none did.
    package func storeWeights<Value: BinaryFloatingPoint>(_ values: [ExpressionKey: Value]) -> Bool {
        var changed = false
        for (key, value) in values {
            guard let (key, clip) = clips.canonicalClip(for: key) else { continue }
            let normalized = clip.normalizedWeight(Double(value))
            let weight = normalized > 0 ? Float(normalized) : nil
            guard weight != weights[key] else { continue }
            if let weight {
                weights[key] = weight
            } else {
                weights.removeValue(forKey: key)
            }
            changed = true
        }
        return changed
    }

    /// Accumulates every active expression and writes what moved through
    /// `applier`.
    package func apply(with applier: ExpressionApplier<Mesh>) {
        let effective = clips.effectiveWeights(of: weights)
        var wroteAnything = false

        scratchMorphWeights.removeAll(keepingCapacity: true)
        scratchColors.removeAll(keepingCapacity: true)
        scratchScales.removeAll(keepingCapacity: true)
        scratchOffsets.removeAll(keepingCapacity: true)

        for (key, weight) in effective {
            for binding in clips[key]?.values ?? [] {
                let morphKey = MorphKey(mesh: ObjectIdentifier(binding.mesh), targetIndex: binding.index)
                scratchMorphWeights[morphKey, default: 0] += Float(binding.weight) * weight
            }
            for binding in materialColorClips[key] ?? [] {
                let colorKey = ColorKey(material: binding.material, type: binding.type)
                scratchColors[colorKey, default: binding.baseValue] +=
                    (binding.targetValue - binding.baseValue) * weight
            }
            for binding in textureTransformClips[key] ?? [] {
                scratchScales[binding.material, default: binding.baseScale] +=
                    (binding.targetScale - binding.baseScale) * weight
                scratchOffsets[binding.material, default: binding.baseOffset] +=
                    (binding.targetOffset - binding.baseOffset) * weight
            }
        }

        for (key, binding) in morphIndex {
            let weight = scratchMorphWeights[key] ?? 0
            guard appliedMorphWeights[key] != weight else { continue }
            appliedMorphWeights[key] = weight
            wroteAnything = true
            applier.setMorphWeight(weight, binding.index, binding.mesh)
        }
        for (key, binding) in colorIndex {
            let color = scratchColors[key] ?? binding.baseValue
            guard appliedColors[key] != color else { continue }
            appliedColors[key] = color
            wroteAnything = true
            applier.setMaterialColor(color, binding.type, binding.material)
        }
        for (material, binding) in transformIndex {
            let scale = scratchScales[material] ?? binding.baseScale
            let offset = scratchOffsets[material] ?? binding.baseOffset
            let applied = SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)
            guard appliedTransforms[material] != applied else { continue }
            appliedTransforms[material] = applied
            wroteAnything = true
            applier.setTextureTransform(scale, offset, binding.baseRotation, binding.material)
        }

        if wroteAnything {
            applier.didApply()
        }
    }
}
