import simd
import VRMKit

/// Every expression a model offers, read off whichever VRM version states them and
/// named by glTF index. A renderer resolves the indices to its own nodes and materials.
package struct VRMExpressionPlan {
    package let clips: [Clip]

    /// One expression: how it accumulates, and what it drives.
    package struct Clip {
        package let name: String
        package let preset: ExpressionPreset?
        package let isBinary: Bool
        package let binaryRounding: BinaryWeightRounding
        package let overrideBlink: ExpressionOverrideType
        package let overrideLookAt: ExpressionOverrideType
        package let overrideMouth: ExpressionOverrideType
        package let morphBinds: [MorphBind]
        package let materialColorBinds: [MaterialColorBind]
        package let textureTransformBinds: [TextureTransformBind]
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
        package let weight: Double
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
                 overrideBlink: .none,
                 overrideLookAt: .none,
                 overrideMouth: .none,
                 morphBinds: group.binds.map {
                     MorphBind(target: .mesh($0.mesh), index: $0.index, weight: $0.weight / 100.0)
                 },
                 materialColorBinds: [],
                 textureTransformBinds: [])
        }
    }

    private static func clips(_ vrm1: VRM1) -> [Clip] {
        (vrm1.expressions?.runtimeClips ?? []).map { clip in
            Clip(name: clip.name,
                 preset: clip.preset,
                 isBinary: clip.expression.isBinary ?? false,
                 binaryRounding: .aboveHalf,
                 overrideBlink: clip.expression.overrideBlink ?? .none,
                 overrideLookAt: clip.expression.overrideLookAt ?? .none,
                 overrideMouth: clip.expression.overrideMouth ?? .none,
                 morphBinds: (clip.expression.morphTargetBinds ?? []).map {
                     MorphBind(target: .node($0.node), index: $0.index, weight: $0.weight)
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
