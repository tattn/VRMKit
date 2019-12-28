//
//  SCNQuaternion+.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2019/12/28.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit

/*
 x, y, and z represent the imaginary values.
 */
@inlinable func SCNQuaternionMake(_ x: SCNFloat, _ y: SCNFloat, _ z: SCNFloat, _ w: SCNFloat) -> SCNQuaternion {
    SCNQuaternion(x, y, z, w)
}

@inlinable func SCNQuaternionMultiply(_ quaternionLeft: SCNQuaternion, _ quaternionRight: SCNQuaternion) -> SCNQuaternion {
    SCNQuaternion(
        quaternionLeft.w * quaternionRight.x +
        quaternionLeft.x * quaternionRight.w +
        quaternionLeft.y * quaternionRight.z -
        quaternionLeft.z * quaternionRight.y,
        
        quaternionLeft.w * quaternionRight.y +
        quaternionLeft.y * quaternionRight.w +
        quaternionLeft.z * quaternionRight.x -
        quaternionLeft.x * quaternionRight.z,
    
        quaternionLeft.w * quaternionRight.z +
        quaternionLeft.z * quaternionRight.w +
        quaternionLeft.x * quaternionRight.y -
        quaternionLeft.y * quaternionRight.x,
    
        quaternionLeft.w * quaternionRight.w -
        quaternionLeft.x * quaternionRight.x -
        quaternionLeft.y * quaternionRight.y -
        quaternionLeft.z * quaternionRight.z
    )
}

@inlinable func SCNQuaternionInvert(_ quaternion: SCNQuaternion) -> SCNQuaternion {
    let scale: SCNFloat = 1.0 / (
        quaternion.x * quaternion.x +
        quaternion.y * quaternion.y +
        quaternion.z * quaternion.z +
        quaternion.w * quaternion.w
    )
    return SCNQuaternion(-quaternion.x * scale, -quaternion.y * scale, -quaternion.z * scale, quaternion.w * scale)
}

@inlinable func SCNQuaternionLength(_ quaternion: SCNQuaternion) -> SCNFloat {
    sqrt(
        quaternion.x * quaternion.x +
        quaternion.y * quaternion.y +
        quaternion.z * quaternion.z +
        quaternion.w * quaternion.w
    )
}

@inlinable func SCNQuaternionNormalize(_ quaternion: SCNQuaternion) -> SCNQuaternion {
    let scale = 1.0 / SCNQuaternionLength(quaternion)
    return SCNQuaternion(quaternion.x * scale, quaternion.y * scale, quaternion.z * scale, quaternion.w * scale)
}

@inlinable func SCNQuaternionRotateVector3(_ quaternion: SCNQuaternion, _ vector: SCNVector3) -> SCNVector3 {
    var rotatedQuaternion: SCNQuaternion = SCNQuaternionMake(vector.x, vector.y, vector.z, 0.0)
    rotatedQuaternion = SCNQuaternionMultiply(SCNQuaternionMultiply(quaternion, rotatedQuaternion), SCNQuaternionInvert(quaternion))
    return SCNVector3Make(rotatedQuaternion.x, rotatedQuaternion.y, rotatedQuaternion.z)
}

/*
 Assumes the axis is already normalized.
 */
@inlinable func SCNQuaternionMakeWithAngleAndAxis(_ radians: SCNFloat, _ x: SCNFloat, _ y: SCNFloat, _ z: SCNFloat) -> SCNQuaternion {
    let halfAngle: SCNFloat = radians * 0.5
    let scale: SCNFloat = SCNFloat(sinf(Float(halfAngle)))
    let q = SCNQuaternion(x: scale * x, y: scale * y, z: scale * z, w: cosf(Float(halfAngle)))
    return q
}


/*
 Assumes the axis is already normalized.
 */
@inlinable func SCNQuaternionMakeWithAngleAndVector3Axis(_ radians: SCNFloat, _ axisVector: SCNVector3) -> SCNQuaternion {
    SCNQuaternionMakeWithAngleAndAxis(radians, axisVector.x, axisVector.y, axisVector.z)
}
