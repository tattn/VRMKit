#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension VRMEntity {
    /// Writes the pose the humanoid bones hold right now, and the expressions the model
    /// wears, as a `.vrma` that holds them.
    ///
    /// The animation's skeleton is a copy of this model's rest skeleton, so what plays
    /// back on this model is the pose as it stands, and on any other model the same
    /// pose retargeted. Every humanoid bone the model rigs gets a rotation track, and
    /// the hips a translation track, so the clip states the whole body rather than
    /// leaving unposed bones to whatever else is driving them. Expressions are the
    /// other way round: only those with a weight above zero are written, so a clip
    /// states the face it wears and leaves the rest of the face to whatever else is
    /// driving it, blinking included.
    ///
    /// - Parameters:
    ///   - name: The glTF animation's name.
    ///   - duration: How long the clip holds the pose. Zero writes a single keyframe.
    /// - Returns: A GLB-packed `.vrma`.
    public func poseAnimationData(name: String? = nil, duration: Float = 0) throws -> Data {
        guard duration.isFinite, duration >= 0 else {
            throw VRMError._invalidArgument("a pose animation's duration cannot be negative, infinite or NaN")
        }
        var document = GLTFEditableDocument()
        let skeleton = try document.addRestSkeleton(of: vrm)
        // Two identical keyframes hold the pose for the duration; one keyframe is a
        // clip with no length.
        let times: [Float] = duration > 0 ? [0, duration] : [0]

        var tracks: [GLTFAnimationTrack] = []
        for bone in HumanoidBone.allCases {
            guard let node = skeleton.bones[bone], let entity = humanoid.node(for: bone) else { continue }
            let transform = entity.transform
            tracks.append(GLTFAnimationTrack(node: node,
                                             times: times,
                                             values: .rotation(times.map { _ in transform.rotation })))
            if bone == .hips {
                tracks.append(GLTFAnimationTrack(node: node,
                                                 times: times,
                                                 values: .translation(times.map { _ in transform.translation })))
            }
        }
        try document.setVRMAnimationHumanoid(skeleton.bones)

        // The expression tracks go last, in the order their nodes were added, so a reader
        // that strips the expression nodes off the end of the node list can pair them up.
        let worn = wornExpressions()
        if !worn.isEmpty {
            let nodes = try document.addExpressionNodes(preset: worn.compactMap(\.presetName),
                                                        custom: worn.compactMap(\.customName))
            for expression in worn {
                let node = expression.presetName.flatMap { nodes.preset[$0] }
                    ?? expression.customName.flatMap { nodes.custom[$0] }
                guard let node else { continue }
                // The weight rides on the node's translation X.
                let weight = SIMD3(expression.weight, 0, 0)
                tracks.append(GLTFAnimationTrack(node: node,
                                                 times: times,
                                                 values: .translation(times.map { _ in weight })))
            }
            try document.setVRMAnimationExpressions(nodes)
        }

        try document.addAnimation(name: name, tracks: tracks)
        return try document.serialize()
    }

    /// An expression worn at a weight above zero, named the way a `.vrma` names it.
    private struct WornExpression {
        let presetName: String?
        let customName: String?
        let weight: Float
    }

    // Kept apart from the authoring loop: the optimizer of Swift 6.3 miscompiles
    // `ExpressionInfo.preset` switched on inside that loop's closures.
    @inline(never)
    private func wornExpressions() -> [WornExpression] {
        var presets: [WornExpression] = []
        var customs: [WornExpression] = []
        for info in availableExpressions {
            let weight = Float(expression(for: info.key))
            guard weight > 0 else { continue }
            switch info.key {
            case .preset(let preset):
                presets.append(WornExpression(presetName: preset.rawValue, customName: nil, weight: weight))
            case .custom(let name):
                customs.append(WornExpression(presetName: nil, customName: name, weight: weight))
            }
        }
        // Presets first, as the nodes are added.
        return presets + customs
    }
}
#endif
