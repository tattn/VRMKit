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

    let vrm = try! VRM(data: Resources.aliciaSolid.data)
    
    override func setUp() {
        super.setUp()
    }
    
    func testMeta() {
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

    func testMaterialProperties() {
        let target = vrm.materialProperties[3]
        XCTAssertEqual(target.name, "Alicia_face")
        XCTAssertEqual(target.shader, "VRM/UnlitTexture")
        XCTAssertEqual(target.renderQueue, 2000)
        XCTAssertTrue((target.floatProperties.value as! [AnyHashable : Any]).isEmpty)
        XCTAssertEqual(target.keywordMap, ["_ALPHAPREMULTIPLY_ON": true])
        XCTAssertEqual(target.tagMap, ["RenderType": "Opaque"])
        XCTAssertEqual(target.textureProperties, ["_MainTex": 3])
        XCTAssertTrue((target.vectorProperties.value as! [AnyHashable : Any]).isEmpty)
    }
}
