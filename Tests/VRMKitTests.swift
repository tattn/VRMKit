//
//  VRMTests.swift
//  VRMKitTests
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import XCTest
import VRMKit

class VRMTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
    }
    
    func testMeta() {
        let vrm = try! VRM(data: Resources.aliciaSolid.data)
        XCTAssertEqual(vrm.meta.title, "Alicia Solid")
        XCTAssertEqual(vrm.meta.author, "DWANGO Co., Ltd.")
        XCTAssertEqual(vrm.meta.contactInformation, "http://3d.nicovideo.jp/alicia/")
        XCTAssertEqual(vrm.meta.reference, "")
        XCTAssertEqual(vrm.meta.texture, 6)
        XCTAssertEqual(vrm.meta.version, "1.0.0")
        
        XCTAssertEqual(vrm.meta.allowedUserName, "Everyone")
        XCTAssertEqual(vrm.meta.violentUssageName, "Disallow")
        XCTAssertEqual(vrm.meta.sexualUssageName, "Disallow")
        XCTAssertEqual(vrm.meta.commercialUssageName, "Allow")
        XCTAssertEqual(vrm.meta.otherPermissionUrl, "http://3d.nicovideo.jp/alicia/rule.html")
        
        XCTAssertEqual(vrm.meta.licenseName, "Other")
        XCTAssertEqual(vrm.meta.otherLicenseUrl, "http://3d.nicovideo.jp/alicia/rule.html")
    }
    
}
