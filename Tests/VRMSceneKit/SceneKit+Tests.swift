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

    func testSCNVector3_sqrMagnitude() {
        let sqrMagnitude = SCNVector3(1, 2, 3).sqrMagnitude
        XCTAssertEqual(sqrMagnitude, 14.0)
    }

    func testSCNVector3_magnitude() {
        XCTAssertEqual(SCNVector3(3, 4, 5).magnitude, 7.071068, accuracy: 0.000001)
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
}
