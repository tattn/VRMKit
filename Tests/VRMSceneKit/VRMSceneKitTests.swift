//
//  VRMSceneKitTests.swift
//  VRMSceneKitTests
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import XCTest
@testable import VRMSceneKit
import SceneKit

class VRMSceneKitTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
    }
    
    override func tearDown() {
        super.tearDown()
    }

    func testBlendShapeClips() {
        let vrmScene = loadVRM()
        XCTAssertEqual(vrmScene.blendShapeClips.count, 18)
        let clip = vrmScene.blendShapeClips[.custom("BlendShape.><")]!
        XCTAssertEqual(clip.name, "BlendShape.><")
        XCTAssertEqual(clip.preset, .unknown)
        XCTAssertEqual(clip.key, .custom("BlendShape.><"))
        XCTAssertEqual(clip.isBinary, false)
        XCTAssertEqual(clip.values.count, 3)
        XCTAssertEqual(clip.values[0].index, 31)
        XCTAssertEqual(clip.values[0].weight, 100)
        XCTAssertEqual(clip.values[0].mesh.name, "face.baked")
    }

    func testBlendShape_SetAndGet() {
        let vrmScene = loadVRM()
        vrmScene.setBlendShape(value: 0.85, for: .preset(.joy))
        XCTAssertEqual(round(vrmScene.blendShape(for: .preset(.joy)) * 100), 85)
    }

    func loadVRM() -> VRMScene {
        let url = Bundle(for: VRMSceneKitTests.self).url(forResource: "AliciaSolid", withExtension: "vrm")!
        let data = try! Data(contentsOf: url)
        let loader = try! VRMSceneLoader(withData: data)
        return try! loader.loadScene()
    }
}
