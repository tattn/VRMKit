import SIMDCompat
import VRMKit

/// What a binary clip makes of a weight of exactly 0.5, which is the one point
/// the two VRM versions disagree on.
public enum BinaryWeightRounding: Sendable {
    /// VRM 0.x rounds a binary blend shape group to the nearest of 0 and 1.
    case nearest
    /// VRM 1.0 raises a binary expression only above 0.5.
    case aboveHalf
}

/// One expression, a VRM 1.0 expression or the VRM 0.x blend shape group loaded as
/// one: how it accumulates, and what it drives, named by glTF index.
public struct VRMExpressionClip: Sendable {
    public typealias OverrideType = VRM1.Expressions.Expression.ExpressionOverrideType

    public var name: String
    public var preset: ExpressionPreset?
    public var isBinary: Bool
    public var binaryRounding: BinaryWeightRounding
    /// How this expression suppresses the blink / lookAt / mouth expressions
    /// while it is active (VRMC_vrm `overrideBlink` / `overrideLookAt` / `overrideMouth`).
    /// A VRM 0.x group declares none of these.
    public var overrideBlink: OverrideType
    public var overrideLookAt: OverrideType
    public var overrideMouth: OverrideType
    public var morphBinds: [MorphBind]
    public var materialColorBinds: [MaterialColorBind]
    public var textureTransformBinds: [TextureTransformBind]

    public var key: ExpressionKey {
        preset.map(ExpressionKey.preset) ?? .custom(name)
    }

    public init(name: String,
                preset: ExpressionPreset? = nil,
                isBinary: Bool = false,
                binaryRounding: BinaryWeightRounding = .aboveHalf,
                overrideBlink: OverrideType = .none,
                overrideLookAt: OverrideType = .none,
                overrideMouth: OverrideType = .none,
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

    /// One morph target the expression drives, weighted 0-1 whichever version wrote it.
    public struct MorphBind: Sendable {
        /// VRM 0.x names the mesh, so every node drawing it is driven; VRM 1.0 names
        /// the one node.
        public enum Target: Hashable, Sendable {
            case mesh(Int)
            case node(Int)
        }

        public var target: Target
        public var index: Int
        public var weight: Float

        public init(target: Target, index: Int, weight: Float) {
            self.target = target
            self.index = index
            self.weight = weight
        }
    }

    public struct MaterialColorBind: Sendable {
        public var material: Int
        public var type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType
        public var targetValue: SIMD4<Float>

        public init(material: Int,
                    type: VRM1.Expressions.Expression.MaterialColorBind.MaterialColorType,
                    targetValue: SIMD4<Float>) {
            self.material = material
            self.type = type
            self.targetValue = targetValue
        }
    }

    public struct TextureTransformBind: Sendable {
        public var material: Int
        public var scale: SIMD2<Float>
        public var offset: SIMD2<Float>

        public init(material: Int, scale: SIMD2<Float>, offset: SIMD2<Float>) {
            self.material = material
            self.scale = scale
            self.offset = offset
        }
    }
}

public extension VRM {
    /// Every expression the model states, in the order it states them, whichever VRM
    /// version wrote them.
    var expressionClips: [VRMExpressionClip] {
        switch self {
        case .v0(let vrm0): Self.clips(vrm0)
        case .v1(let vrm1): Self.clips(vrm1)
        }
    }

    /// A 0.x group is read as the expression it stands for, and its 0-100 weights
    /// normalized to 0-1, so both versions come out as one kind of clip.
    private static func clips(_ vrm0: VRM0) -> [VRMExpressionClip] {
        vrm0.blendShapeMaster.blendShapeGroups.map { group in
            VRMExpressionClip(name: group.name,
                 preset: group.expressionPreset,
                 isBinary: group.isBinary,
                 binaryRounding: .nearest,
                 morphBinds: group.binds.map {
                     VRMExpressionClip.MorphBind(target: .mesh($0.mesh), index: $0.index, weight: Float($0.weight / 100.0))
                 })
        }
    }

    private static func clips(_ vrm1: VRM1) -> [VRMExpressionClip] {
        (vrm1.expressions?.runtimeClips ?? []).map { clip in
            VRMExpressionClip(name: clip.name,
                 preset: clip.preset,
                 isBinary: clip.expression.isBinary ?? false,
                 overrideBlink: clip.expression.overrideBlink ?? .none,
                 overrideLookAt: clip.expression.overrideLookAt ?? .none,
                 overrideMouth: clip.expression.overrideMouth ?? .none,
                 morphBinds: (clip.expression.morphTargetBinds ?? []).map {
                     VRMExpressionClip.MorphBind(target: .node($0.node), index: $0.index, weight: Float($0.weight))
                 },
                 materialColorBinds: (clip.expression.materialColorBinds ?? []).map {
                     VRMExpressionClip.MaterialColorBind(material: $0.material, type: $0.type, targetValue: $0.targetValue)
                 },
                 textureTransformBinds: (clip.expression.textureTransformBinds ?? []).map {
                     VRMExpressionClip.TextureTransformBind(material: $0.material, scale: $0.scale, offset: $0.offset)
                 })
        }
    }
}
