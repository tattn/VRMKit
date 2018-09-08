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

    func testHumanoid() {
        XCTAssertEqual(vrm.humanoid.armStretch, 0.05)
        XCTAssertEqual(vrm.humanoid.feetSpacing, 0)
        XCTAssertEqual(vrm.humanoid.hasTranslationDoF, false)
        XCTAssertEqual(vrm.humanoid.legStretch, 0.05)
        XCTAssertEqual(vrm.humanoid.lowerArmTwist, 0.5)
        XCTAssertEqual(vrm.humanoid.lowerLegTwist, 0.5)
        XCTAssertEqual(vrm.humanoid.upperArmTwist, 0.5)
        XCTAssertEqual(vrm.humanoid.upperLegTwist, 0.5)
        XCTAssertEqual(vrm.humanoid.humanBones[0].bone, "hips")
        XCTAssertEqual(vrm.humanoid.humanBones[0].node, 3)
        XCTAssertEqual(vrm.humanoid.humanBones[0].useDefaultValues, true)
    }

    func testBlendShapeMaster() {
        let target = vrm.blendShapeMaster.blendShapeGroups[1]
        XCTAssertEqual(target.binds[0].index, 0)
        XCTAssertEqual(target.binds[0].mesh, 3)
        XCTAssertEqual(target.binds[0].weight, 100)
        XCTAssertTrue(target.materialValues.isEmpty)
        XCTAssertEqual(target.name, "A")
        XCTAssertEqual(target.presetName, "a")
    }

    func testFirstPerson() {
        XCTAssertEqual(vrm.firstPerson.firstPersonBone, 36)
        XCTAssertEqual(vrm.firstPerson.firstPersonBoneOffset.x, 0)
        XCTAssertEqual(vrm.firstPerson.firstPersonBoneOffset.y, 0.06)
        XCTAssertEqual(vrm.firstPerson.firstPersonBoneOffset.z, 0)
        XCTAssertEqual(vrm.firstPerson.meshAnnotations[0].firstPersonFlag, "Auto")
        XCTAssertEqual(vrm.firstPerson.meshAnnotations[0].mesh, 0)
    }
}
