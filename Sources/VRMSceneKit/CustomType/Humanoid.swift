//
//  Humanoid.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 2019/02/11.
//  Copyright © 2019 tattn. All rights reserved.
//

import VRMKit
import SceneKit

public final class Humanoid {
    var bones: [Bones: SCNNode] = [:]

    func setUp(humanoid: VRM.Humanoid, nodes: [SCNNode?]) {
        bones = humanoid.humanBones.reduce(into: [:]) { result, humanBone in
            guard let bone = Bones(rawValue: humanBone.bone),
                let node = nodes[humanBone.node] else { return }
            result[bone] = node
        }
    }

    public func node(for bone: Bones) -> SCNNode? {
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
