//
//  SceneKit+Tests.swift
//  VRMSceneKitTests
//
//  Created by Tatsuya Tanaka on 2019/12/29.
//  Copyright © 2019 tattn. All rights reserved.
//

import XCTest
import SceneKit
@testable import VRMSceneKit

class SceneKit_Tests: XCTestCase {

    func testSCNVector3_sqrMagnitude() {
        let magnitude = SCNVector3.sqrMagnitude(SCNVector3(1, 2, 3))
        XCTAssertEqual(magnitude, 14.0)
    }

    func testSCNVector3_add() {
        let (v1, v2) = (SCNVector3(1, 2, 3), SCNVector3(4, 5, 6))
        XCTAssertEqual(v1 + v2, SCNVector3(5, 7, 9))
    }

    func testSCNVector3_sub() {
        let (v1, v2) = (SCNVector3(1, 2, 3), SCNVector3(4, 5, 6))
        XCTAssertEqual(v2 - v1, SCNVector3(3, 3, 3))
    }

    func testSCNVector3_mul() {
        XCTAssertEqual(SCNVector3(1, 2, 3) * 4, SCNVector3(4, 8, 12))
    }

    func testSCNVector3_div() {
        XCTAssertEqual(SCNVector3(4, 8, 12) / 4, SCNVector3(1, 2, 3))
    }

    func testSCNVector3_add_assign() {
        var (v1, v2) = (SCNVector3(1, 2, 3), SCNVector3(4, 5, 6))
        v1 += v2
        XCTAssertEqual(v1, SCNVector3(5, 7, 9))
        XCTAssertEqual(v2, SCNVector3(4, 5, 6))
    }

    func testSCNVector3_sub_assign() {
        var (v1, v2) = (SCNVector3(1, 2, 3), SCNVector3(4, 5, 6))
        v2 -= v1
        XCTAssertEqual(v2, SCNVector3(3, 3, 3))
        XCTAssertEqual(v1, SCNVector3(1, 2, 3))
    }

    func testSCNVector3_mul_assign() {
        var v = SCNVector3(1, 2, 3)
        v *= 4
        XCTAssertEqual(v, SCNVector3(4, 8, 12))
    }

    func testSCNVector3_div_assign() {
        var v = SCNVector3(4, 8, 12)
        v /= 4
        XCTAssertEqual(v, SCNVector3(1, 2, 3))
    }

    func testSCNVector3_length() {
        XCTAssertEqual(SCNVector3(3, 4, 5).length, 7.071068, accuracy: 0.000001)
    }

    func testSCNVector3_normalized() {
        let vec = SCNVector3(1, 2, 3).normalized
        XCTAssertEqualFuzzy(vec, SCNVector3(0.26726124, 0.5345225, 0.8017837))
    }

    func testSCNVector3_normalize() {
        var vec = SCNVector3(1, 2, 3)
        vec.normalize()
        XCTAssertEqualFuzzy(vec, SCNVector3(0.26726124, 0.5345225, 0.8017837))
    }

    func testSCNVector3_cross() {
        let (vec1, vec2) = (SCNVector3(1, 2, 3), SCNVector3(4, 5, 6))
        let result = cross(vec1, vec2)
        XCTAssertEqualFuzzy(result, SCNVector3(-3, 6, -3))
    }

    func testSCNVector3_normal() {
        let (vec1, vec2, vec3) = (SCNVector3(0, 0, 5), SCNVector3(5, 0, 1), SCNVector3(1, 5, 0))
        let result = normal(vec1, vec2, vec3)
        XCTAssertEqualFuzzy(result, SCNVector3(0.52235174, 0.5484693, 0.6529396))
    }

    func testSCNVector3_dot() {
        let (vec1, vec2) = (SCNVector3(1, 2, 3), SCNVector3(4, 5, 6))
        let result = dot(vec1, vec2)
        XCTAssertEqual(result, 32.0)
    }

    func testSCNMatrix4_initWithArray() {
        do {
            let v: [SCNFloat] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
            let matrix = try! SCNMatrix4(v)
            XCTAssertEqual(v, matrix.array)
        }

        do {
            let v: [SCNFloat] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
            XCTAssertThrowsError(try SCNMatrix4(v))
            let v2: [SCNFloat] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
            XCTAssertThrowsError(try SCNMatrix4(v2))
        }
    }

    func testSCNMatrix4_mulByMatrix4() {
        let matrix = try! SCNMatrix4([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        let expected = SCNMatrix4(m11: 90.0, m12: 100.0, m13: 110.0, m14: 120.0, m21: 202.0, m22: 228.0, m23: 254.0, m24: 280.0, m31: 314.0, m32: 356.0, m33: 398.0, m34: 440.0, m41: 426.0, m42: 484.0, m43: 542.0, m44: 600.0)
        XCTAssertEqual(matrix * matrix, expected)
    }

    func testSCNQuaternion_init_fromTo() {
        do {
            let (from, to) = (SCNVector3(5, 0, 0), SCNVector3(0, 5, 0))
            let fromTo = SCNQuaternion(from: from, to: to)
            XCTAssertEqualFuzzy(fromTo, SCNQuaternion(x: 0.0, y: 0.0, z: 0.70710677, w: 0.70710677))
            XCTAssertEqualFuzzy(fromTo * from, to)
            let toFrom = SCNQuaternion(from: to, to: from)
            XCTAssertEqualFuzzy(toFrom, SCNQuaternion(x: 0.0, y: 0.0, z: -0.70710677, w: 0.70710677))
            XCTAssertEqualFuzzy(toFrom * to, from)
        }
        do {
            let (from, to) = (SCNVector3(1, 2, 5), SCNVector3(2, 1, 2))
            let fromTo = SCNQuaternion(from: from, to: to)
            XCTAssertEqualFuzzy(fromTo, SCNQuaternion(x: -0.03162139, y: 0.25297117, z: -0.094864205, w: 0.96229225))
            XCTAssertEqualFuzzy((fromTo * from).normalized, to.normalized)
            let toFrom = SCNQuaternion(from: to, to: from)
            XCTAssertEqualFuzzy(toFrom, SCNQuaternion(x: 0.03162139, y: -0.25297117, z: 0.094864205, w: 0.96229225))
            XCTAssertEqualFuzzy((toFrom * to).normalized, from.normalized)
        }
    }

    func testSCNQuaternion_init_angleAxis() {
        do {
            let quat = SCNQuaternion(angle: SCNFloat.pi / 2, axis: SCNVector3(0, 1, 0))
            XCTAssertEqualFuzzy(quat * SCNVector3(1, 0, 0), SCNVector3(0, 0, -1))
        }
        do {
            let quat = SCNQuaternion(angle: -SCNFloat.pi / 3, axis: SCNVector3(3, 2, 1).normalized)
            XCTAssertEqualFuzzy(quat * SCNVector3(1, 2, 3), SCNVector3(0.6456084, 3.5659258, 0.9313232))
        }
    }

    func testSCNQuaternion_mulWithSCNQuaternion() {
        do {
            let xAxis = SCNQuaternion(angle: SCNFloat.pi / 2, axis: .init(1, 0, 0))
            let yAxis = SCNQuaternion(angle: SCNFloat.pi / 2, axis: .init(0, 1, 0))
            let zAxis = SCNQuaternion(angle: SCNFloat.pi / 2, axis: .init(0, 0, 1))
            XCTAssertEqualFuzzy(xAxis * yAxis * zAxis * SCNVector3(1, 0, 0), SCNVector3(0, 0, 1))
            XCTAssertEqualFuzzy(yAxis * xAxis * zAxis * SCNVector3(1, 0, 0), SCNVector3(1, 0, 0))
            XCTAssertEqualFuzzy(zAxis * xAxis * yAxis * SCNVector3(1, 0, 0), SCNVector3(-1, 0, 0))
        }
        do {
            let q1 = SCNQuaternion(angle: SCNFloat.pi / 4, axis: SCNVector3(1, 0.2, 0.1).normalized)
            let q2 = SCNQuaternion(angle: -SCNFloat.pi / 5, axis: SCNVector3(0.1, 0.4, 1).normalized)
            XCTAssertEqualFuzzy(q1 * q2, SCNQuaternion(0.31171754, 0.07108627, -0.26896468, 0.90853566))
        }
    }

    func testSCNQuaternion_mulWithSCNVector3() {
        let q = SCNQuaternion(angle: SCNFloat.pi / 4, axis: SCNVector3(1, 0.2, 0.1).normalized)
        XCTAssertEqualFuzzy(q * SCNVector3(5, 1, 2), SCNVector3(5.2488613, -0.026729956, 1.5648444))
    }

    func testSCNQuaternion_inverted() {
        let q = SCNQuaternion(angle: SCNFloat.pi / 4, axis: SCNVector3(1, 0.2, 0.1).normalized)
        XCTAssertEqualFuzzy(q.inverted, SCNQuaternion(-0.37346077, -0.07469215, -0.037346076, 0.92387944))
    }
}
