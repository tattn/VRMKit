//
//  SCNMatrix4+Tests.swift
//  VRMSceneKitTests
//
//  Created by Tatsuya Tanaka on 2019/12/29.
//  Copyright © 2019 tattn. All rights reserved.
//

import XCTest
import SceneKit
@testable import VRMSceneKit

class SCNMatrix4_Tests: XCTestCase {

    private let testMatrix: SCNMatrix4 = {
        let node = SCNNode()
        node.position = .init(3, 4, 5)
        node.rotation = .init(1, 0, 0, CGFloat.pi)
        node.scale = .init(1, 2, 3)
        return node.transform
    }()

    func test_testMatrix() {
        let result = SCNMatrix4(m11: 0.99999976, m12: 0.0, m13: 0.0, m14: 0.0, m21: 0.0, m22: -2.0, m23: -1.7484554e-07, m24: 0.0, m31: 0.0, m32: 2.6226832e-07, m33: -3.0, m34: 0.0, m41: 3.0, m42: 4.0, m43: 5.0, m44: 1.0)
        for (m1, m2) in zip(testMatrix.array, result.array) {
            XCTAssertEqual(m1, m2, accuracy: 0.000000001)
        }
    }

    func test_multiplyPointWithSCNVector3() {
        let vec = testMatrix.multiplyPoint(SCNVector3(1, 2, 3))
        XCTAssertEqual(vec, SCNVector3(x: 0.99999976, y: -3.9999993, z: -9.0))
    }

    func test_multiplyPointWithSCNVector4() {
        let vec = testMatrix.multiplyPoint(SCNVector4(1, 2, 3, 4))
        XCTAssertEqual(vec, SCNVector4(x: 13.0, y: 12.000001, z: 11.0, w: 4.0))
    }
}
