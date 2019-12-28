//
//  SCNVector3+.swift
//  VRMKit
//
//  Created by Tomoya Hirano on 2019/12/21.
//  Copyright © 2019 tattn. All rights reserved.
//

import VRMKit
import SceneKit

extension VRM.Vector3 {
    func createSCNVector3() -> SCNVector3 {
        return .init(x: SCNFloat(x), y: SCNFloat(y), z: SCNFloat(z))
    }
}

@inlinable func SCNVector3Length(_ vector: SCNVector3) -> SCNFloat {
    sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
}

// Convenience
@inlinable func SCNVector3LengthSquared(_ vector: SCNVector3) -> SCNFloat {
    vector.x * vector.x + vector.y * vector.y + vector.z * vector.z
}

@inlinable func SCNVector3DotProduct(_ vectorLeft: SCNVector3, _ vectorRight: SCNVector3) -> SCNFloat {
    vectorLeft.x * vectorRight.x + vectorLeft.y * vectorRight.y + vectorLeft.z * vectorRight.z
}
