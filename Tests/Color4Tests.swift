//
//  Color4Tests.swift
//  VRMKitTests
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import XCTest
import VRMKit

class Color4Tests: XCTestCase {
    
    override func setUp() {
        super.setUp()
    }

    func testDecode() {
        let colorArray: [Float] = [1.0, 0.5, 0.2, 1.0]
        let data = try! JSONEncoder().encode(colorArray)
        let color4 = try! JSONDecoder().decode(GLTF.Color4.self, from: data)
        XCTAssertEqual(colorArray[0], color4.r)
        XCTAssertEqual(colorArray[1], color4.g)
        XCTAssertEqual(colorArray[2], color4.b)
        XCTAssertEqual(colorArray[3], color4.a)
    }
    
}
