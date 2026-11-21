import SIMDCompat
import VRMKit

/// What a binary clip makes of a weight of exactly 0.5, which is the one point
/// the two VRM versions disagree on.
package enum BinaryWeightRounding {
    /// VRM 0.x rounds a binary blend shape group to the nearest of 0 and 1.
    case nearest
    /// VRM 1.0 raises a binary expression only above 0.5.
    case aboveHalf
}

/// Every expression a model offers, read off whichever VRM version states them and
/// named by glTF index.
package struct VRMExpressionPlan {
    package let clips: [Clip]

    /// One expression, a VRM 1.0 expression or the VRM 0.x blend shape group loaded as
    /// one: how it accumulates, and what it drives.
    package struct Clip {
        package let name: String
        package let preset: ExpressionPreset?
        let isBinary: Bool
        let binaryRounding: BinaryWeightRounding
        /// How this expression suppresses the blink / lookAt / mouth expressions
        /// while it is active (VRMC_vrm `overrideBlink` / `overrideLookAt` / `overrideMouth`).
        /// A VRM 0.x group declares none of these.
        let overrideBlink: ExpressionOverrideType
        let overrideLookAt: ExpressionOverrideType
        let overrideMouth: ExpressionOverrideType
        package let morphBinds: [MorphBind]
        let materialColorBinds: [MaterialColorBind]
        let textureTransformBinds: [TextureTransformBind]

        package var key: ExpressionKey {
            preset.map(ExpressionKey.preset) ?? .custom(name)
        }

        package init(name: String,
                     preset: ExpressionPreset?,
                     isBinary: Bool,
                     binaryRounding: BinaryWeightRounding = .aboveHalf,
                     overrideBlink: ExpressionOverrideType = .none,
                     overrideLookAt: ExpressionOverrideType = .none,
                     overrideMouth: ExpressionOverrideType = .none,
                     morphBinds: [MorphBind] = [],
                     materialColorBinds: [MaterialColorBind] = [],
                     textureTransformBinds: [TextureTransformBind] = []) {
            self.name = name
            self.preset = preset
            self.isBinary = isBinary
            self.binaryRounding = binaryRounding
            self.overrideBlink = overrideBlink
            self.overrideLookAt = overrideLookAt
            self.overrideMouth = overrideMouth
            self.morphBinds = morphBinds
            self.materialColorBinds = materialColorBinds
            self.textureTransformBinds = textureTransformBinds
        }

        /// Clamps `value` to 0...1, resolving a binary clip to one of its ends.
        func normalizedWeight(_ value: Float) -> Float {
            let clamped = min(max(value, 0), 1)
            guard isBinary else { return clamped }
            switch binaryRounding {
            case .nearest: return clamped.rounded()
            case .aboveHalf: return clamped > 0.5 ? 1 : 0
            }
        }

        func overrideType(for group: ExpressionOverrideGroup) -> ExpressionOverrideType {
            switch group {
            case .blink: return overrideBlink
            case .lookAt: return overrideLookAt
            case .mouth: return overrideMouth
            }
        }
    }

    /// One morph target the expression drives, weighted 0-1 whichever version wrote it.
    package struct MorphBind {
        /// VRM 0.x names the mesh, so every node drawing it is driven; VRM 1.0 names
        /// the one node.
        package enum Target {
            case mesh(Int)
            case node(Int)
        }

        package let target: Target
        package let index: Int
        package let weight: Float
    }

    package struct MaterialColorBind {
        package let material: Int
        package let type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
        package let targetValue: SIMD4<Float>
    }

    package struct TextureTransformBind {
        package let material: Int
        package let scale: SIMD2<Float>
        package let offset: SIMD2<Float>
    }

    package init(vrm: VRM) {
        switch vrm {
        case .v0(let vrm0): clips = Self.clips(vrm0)
        case .v1(let vrm1): clips = Self.clips(vrm1)
        }
    }

    /// A 0.x group is read as the expression it stands for, and its 0-100 weights
    /// normalized to 0-1, so both versions come out as one kind of clip.
    private static func clips(_ vrm0: VRM0) -> [Clip] {
        vrm0.blendShapeMaster.blendShapeGroups.map { group in
            Clip(name: group.name,
                 preset: group.expressionPreset,
                 isBinary: group.isBinary,
                 binaryRounding: .nearest,
                 morphBinds: group.binds.map {
                     MorphBind(target: .mesh($0.mesh), index: $0.index, weight: Float($0.weight / 100.0))
                 })
        }
    }

    private static func clips(_ vrm1: VRM1) -> [Clip] {
        (vrm1.expressions?.runtimeClips ?? []).map { clip in
            Clip(name: clip.name,
                 preset: clip.preset,
                 isBinary: clip.expression.isBinary ?? false,
                 overrideBlink: clip.expression.overrideBlink ?? .none,
                 overrideLookAt: clip.expression.overrideLookAt ?? .none,
                 overrideMouth: clip.expression.overrideMouth ?? .none,
                 morphBinds: (clip.expression.morphTargetBinds ?? []).map {
                     MorphBind(target: .node($0.node), index: $0.index, weight: Float($0.weight))
                 },
                 materialColorBinds: (clip.expression.materialColorBinds ?? []).map {
                     MaterialColorBind(material: $0.material, type: $0.type, targetValue: $0.targetValue)
                 },
                 textureTransformBinds: (clip.expression.textureTransformBinds ?? []).map {
                     TextureTransformBind(material: $0.material, scale: $0.scale, offset: $0.offset)
                 })
        }
    }
}
