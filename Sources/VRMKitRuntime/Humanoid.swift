import VRMKit

public final class Humanoid<Node> {
    package var bones: [Bones: Node] = [:]

    public init() {}

    package func setUp(humanoid: VRM0.Humanoid, nodes: [Node?]) {
        bones = humanoid.humanBones.reduce(into: [:]) { result, humanBone in
            guard let bone = Bones(rawValue: humanBone.bone) else { return }
            guard nodes.indices.contains(humanBone.node),
                  let node = nodes[humanBone.node] else { return }
            result[bone] = node
        }
    }

    package func setUp(humanoid: VRM1.Humanoid, nodes: [Node?]) {
        let humanBones = humanoid.humanBones
        let mappings: [(Bones, VRM1.Humanoid.HumanBones.HumanBone?)] = [
            (.hips, humanBones.hips),
            (.spine, humanBones.spine),
            (.chest, humanBones.chest),
            (.upperChest, humanBones.upperChest),
            (.neck, humanBones.neck),
            (.head, humanBones.head),
            (.leftEye, humanBones.leftEye),
            (.rightEye, humanBones.rightEye),
            (.jaw, humanBones.jaw),
            (.leftUpperLeg, humanBones.leftUpperLeg),
            (.leftLowerLeg, humanBones.leftLowerLeg),
            (.leftFoot, humanBones.leftFoot),
            (.leftToes, humanBones.leftToes),
            (.rightUpperLeg, humanBones.rightUpperLeg),
            (.rightLowerLeg, humanBones.rightLowerLeg),
            (.rightFoot, humanBones.rightFoot),
            (.rightToes, humanBones.rightToes),
            (.leftShoulder, humanBones.leftShoulder),
            (.leftUpperArm, humanBones.leftUpperArm),
            (.leftLowerArm, humanBones.leftLowerArm),
            (.leftHand, humanBones.leftHand),
            (.rightShoulder, humanBones.rightShoulder),
            (.rightUpperArm, humanBones.rightUpperArm),
            (.rightLowerArm, humanBones.rightLowerArm),
            (.rightHand, humanBones.rightHand),
            (.leftThumbMetacarpal, humanBones.leftThumbMetacarpal),
            (.leftThumbProximal, humanBones.leftThumbProximal),
            (.leftThumbDistal, humanBones.leftThumbDistal),
            (.leftIndexProximal, humanBones.leftIndexProximal),
            (.leftIndexIntermediate, humanBones.leftIndexIntermediate),
            (.leftIndexDistal, humanBones.leftIndexDistal),
            (.leftMiddleProximal, humanBones.leftMiddleProximal),
            (.leftMiddleIntermediate, humanBones.leftMiddleIntermediate),
            (.leftMiddleDistal, humanBones.leftMiddleDistal),
            (.leftRingProximal, humanBones.leftRingProximal),
            (.leftRingIntermediate, humanBones.leftRingIntermediate),
            (.leftRingDistal, humanBones.leftRingDistal),
            (.leftLittleProximal, humanBones.leftLittleProximal),
            (.leftLittleIntermediate, humanBones.leftLittleIntermediate),
            (.leftLittleDistal, humanBones.leftLittleDistal),
            (.rightThumbMetacarpal, humanBones.rightThumbMetacarpal),
            (.rightThumbProximal, humanBones.rightThumbProximal),
            (.rightThumbDistal, humanBones.rightThumbDistal),
            (.rightIndexProximal, humanBones.rightIndexProximal),
            (.rightIndexIntermediate, humanBones.rightIndexIntermediate),
            (.rightIndexDistal, humanBones.rightIndexDistal),
            (.rightMiddleProximal, humanBones.rightMiddleProximal),
            (.rightMiddleIntermediate, humanBones.rightMiddleIntermediate),
            (.rightMiddleDistal, humanBones.rightMiddleDistal),
            (.rightRingProximal, humanBones.rightRingProximal),
            (.rightRingIntermediate, humanBones.rightRingIntermediate),
            (.rightRingDistal, humanBones.rightRingDistal),
            (.rightLittleProximal, humanBones.rightLittleProximal),
            (.rightLittleIntermediate, humanBones.rightLittleIntermediate),
            (.rightLittleDistal, humanBones.rightLittleDistal)
        ]
        bones = mappings.reduce(into: [:]) { result, mapping in
            guard let humanBone = mapping.1,
                  nodes.indices.contains(humanBone.node),
                  let node = nodes[humanBone.node] else { return }
            result[mapping.0] = node
        }
    }

    public func node(for bone: Bones) -> Node? {
        return bones[bone]
    }

    public enum Bones: String {
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
        case leftThumbProximal
        case leftThumbMetacarpal
        case leftThumbIntermediate
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
        case rightThumbProximal
        case rightThumbMetacarpal
        case rightThumbIntermediate
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
}
