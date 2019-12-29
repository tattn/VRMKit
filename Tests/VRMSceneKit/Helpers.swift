//
//  Helpers.swift
//  VRMSceneKitTests
//
//  Created by Tatsuya Tanaka on 2019/12/29.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit
import XCTest

protocol ArrayConvertible {
    var array: [SCNFloat] { get }
}

extension SCNVector3: ArrayConvertible {
    var array: [SCNFloat] {
        [x, y, z]
    }
}

extension SCNVector3: Equatable {
    public static func == (lhs: SCNVector3, rhs: SCNVector3) -> Bool {
        lhs.array == rhs.array
    }
}

extension SCNVector4: ArrayConvertible {
    var array: [SCNFloat] {
        [x, y, z, w]
    }
}

extension SCNVector4: Equatable {
    public static func == (lhs: SCNVector4, rhs: SCNVector4) -> Bool {
        lhs.array == rhs.array
    }
}

extension SCNMatrix4: ArrayConvertible {
    var array: [SCNFloat] {
        [
            m11,
            m12,
            m13,
            m14,
            m21,
            m22,
            m23,
            m24,
            m31,
            m32,
            m33,
            m34,
            m41,
            m42,
            m43,
            m44
        ]
    }
}

extension SCNMatrix4: Equatable {
    public static func == (lhs: SCNMatrix4, rhs: SCNMatrix4) -> Bool {
        lhs.array == rhs.array
    }
}

func XCTAssertEqualFuzzy<T: ArrayConvertible>(_ expression1: T, _ expression2: T, accuracy: SCNFloat = 0.000001, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    for (e1, e2) in zip(expression1.array, expression2.array) {
        XCTAssertEqual(e1, e2, accuracy: accuracy, message(), file: file, line: line)
    }
}
