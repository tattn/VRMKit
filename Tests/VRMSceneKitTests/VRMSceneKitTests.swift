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

    func testHumanoid() {
        let humanoid = loadVRM().humanoid
        XCTAssertEqual(humanoid.bones.count, 53)
        let neckPosition = humanoid.node(for: .neck)!.position
        XCTAssertEqual(round(neckPosition.x * 1000), 0)
        XCTAssertEqual(round(neckPosition.y * 1000), 140)
        XCTAssertEqual(round(neckPosition.z * 1000), 14)
    }

    func testBlendShapeClips() {
        let clips = loadVRM().blendShapeClips
        XCTAssertEqual(clips.count, 18)
        let clip = clips[.custom("><")]!
        XCTAssertEqual(clip.name, "><")
        XCTAssertEqual(clip.preset, .unknown)
        XCTAssertEqual(clip.key, .custom("><"))
        XCTAssertEqual(clip.isBinary, false)
        XCTAssertEqual(clip.values.count, 3)
        XCTAssertEqual(clip.values[0].index, 31)
        XCTAssertEqual(clip.values[0].weight, 100)
        XCTAssertEqual(clip.values[0].mesh.name, "face.baked")
        XCTAssertEqual(clips.filter({ $0.key.isPreset }).count, 17)
        XCTAssertEqual(clips.filter({ !$0.key.isPreset }).count, 1)
    }

    func testBlendShape_SetAndGet() {
        let node = loadVRM()
        node.setBlendShape(value: 0.85, for: .preset(.joy))
        XCTAssertEqual(round(node.blendShape(for: .preset(.joy)) * 100), 85)
    }

    func loadVRM() -> VRMNode {
        let url = Bundle.module.url(forResource: "AliciaSolid", withExtension: "vrm")!
        let data = try! Data(contentsOf: url)
        let loader = try! VRMSceneLoader(withData: data)
        return try! loader.loadScene().vrmNode
    }
}
