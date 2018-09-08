//
//  ExtensionsTests.swift
//  VRMKitTests
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import XCTest
import VRMKit

class ExtensionsTests: XCTestCase {

    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()
    
    override func setUp() {
        super.setUp()
    }
    
    override func tearDown() {
        super.tearDown()
    }
    
    func testInt() {
        encodeAndDecode(["value": 1])
    }

    func testStringIntDictionary() {
        encodeAndDecode(["value": ["key": 1]])
    }

    func testDoubleArray() {
        encodeAndDecode([1.1, 2.2, 3.3])
    }

    func testNestedArray() {
        encodeAndDecode([[[["one", "two", "three"]]]])
    }

    private func encodeAndDecode<T: Equatable>(_ expectedValue: T) {
        let extensions = GLTF.Extensions(expectedValue)
        let data = try! jsonEncoder.encode(extensions)
        let decodedValue = try! jsonDecoder.decode(GLTF.Extensions.self, from: data)
        XCTAssertEqual(decodedValue.value as! T, expectedValue)
    }
}
