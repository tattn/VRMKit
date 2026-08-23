import Foundation

/// A bone of the VRM humanoid rig, named as VRM 1.0 names it.
///
/// The two VRM versions disagree about the thumb: 0.x counts its joints
/// proximal / intermediate / distal where 1.0 counts the same three
/// metacarpal / proximal / distal. One name per joint is what lets a bone mean
/// the same anatomy whichever version a model is, and ``init(vrm0Name:)``
/// translates at the 0.x boundary.
public enum HumanoidBone: String, CaseIterable, Sendable {
    case hips
    case leftUpperLeg
    case rightUpperLeg
    case leftLowerLeg
    case rightLowerLeg
    case leftFoot
    case rightFoot
    case spine
    case chest
    case neck
    case head
    case leftShoulder
    case rightShoulder
    case leftUpperArm
    case rightUpperArm
    case leftLowerArm
    case rightLowerArm
    case leftHand
    case rightHand
    case leftToes
    case rightToes
    case leftEye
    case rightEye
    case jaw
    case leftThumbMetacarpal
    case leftThumbProximal
    case leftThumbDistal
    case leftIndexProximal
    case leftIndexIntermediate
    case leftIndexDistal
    case leftMiddleProximal
    case leftMiddleIntermediate
    case leftMiddleDistal
    case leftRingProximal
    case leftRingIntermediate
    case leftRingDistal
    case leftLittleProximal
    case leftLittleIntermediate
    case leftLittleDistal
    case rightThumbMetacarpal
    case rightThumbProximal
    case rightThumbDistal
    case rightIndexProximal
    case rightIndexIntermediate
    case rightIndexDistal
    case rightMiddleProximal
    case rightMiddleIntermediate
    case rightMiddleDistal
    case rightRingProximal
    case rightRingIntermediate
    case rightRingDistal
    case rightLittleProximal
    case rightLittleIntermediate
    case rightLittleDistal
    case upperChest
}

