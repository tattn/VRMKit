//
//  BinaryGLTFTests.swift
//  VRMKitTests
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import XCTest
import VRMKit

class BinaryGLTFTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
    }
    
    func testLoadVRM() {
        let url = Bundle(for: BinaryGLTFTests.self).url(forResource: "AliciaSolid", withExtension: "vrm")!
        let data = try! Data(contentsOf: url)
        let binaryGltf = try! BinaryGLTF(from: data)
        let json = binaryGltf.jsonData
        XCTAssertEqual(json.asset.generator, "UniGLTF")
        XCTAssertEqual(json.asset.version, "2.0")
    }
    
}
