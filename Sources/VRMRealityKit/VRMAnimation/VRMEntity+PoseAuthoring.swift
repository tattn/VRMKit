#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension VRMEntity {
    /// Writes the pose the humanoid bones hold right now as a `.vrma` that holds it.
    ///
    /// The animation's skeleton is a copy of this model's rest skeleton, so what plays
    /// back on this model is the pose as it stands, and on any other model the same
    /// pose retargeted. Every humanoid bone the model rigs gets a rotation track, and
    /// the hips a translation track, so the clip states the whole body rather than
    /// leaving unposed bones to whatever else is driving them.
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
        try document.addAnimation(name: name, tracks: tracks)
        return try document.serialize()
    }
}
#endif
