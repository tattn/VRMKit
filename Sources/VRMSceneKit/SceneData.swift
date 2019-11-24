//
//  SceneData.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation
import VRMKit
import SceneKit

final class SceneData {
    var scene: VRMScene?
    var scenes: [VRMScene?]
    var cameras: [SCNCamera?]
    var nodes: [SCNNode?]
    var skins: [SCNSkinner?]
    var animationChannels: [[CAAnimation?]?]
    var animationSamplers: [[CAAnimation?]?]
    var meshes: [SCNNode?]
    var accessors: [Any?]
    var durations: [CFTimeInterval?]
    var bufferViews: [Data?] = []
    var buffers: [Data?] = []
    var materials: [SCNMaterial?] = []
    var textures: [SCNMaterialProperty?] = []
    var images: [UIImage?] = []

    init(vrm: GLTF) {
        scenes = Array(repeating: nil, count: vrm.scenes?.count ?? 0)
        cameras = Array(repeating: nil, count: vrm.cameras?.count ?? 0)
        nodes = Array(repeating: nil, count: vrm.nodes?.count ?? 0)
        skins = Array(repeating: nil, count: vrm.skins?.count ?? 0)
        animationChannels = Array(repeating: nil, count: vrm.animations?.count ?? 0)
        animationSamplers = Array(repeating: nil, count: vrm.animations?.count ?? 0)
        meshes = Array(repeating: nil, count: vrm.meshes?.count ?? 0)
        accessors = Array(repeating: nil, count: vrm.accessors?.count ?? 0)
        durations = Array(repeating: nil, count: vrm.accessors?.count ?? 0)
        bufferViews = Array(repeating: nil, count: vrm.bufferViews?.count ?? 0)
        buffers = Array(repeating: nil, count: vrm.buffers?.count ?? 0)
        materials = Array(repeating: nil, count: vrm.materials?.count ?? 0)
        textures = Array(repeating: nil, count: vrm.textures?.count ?? 0)
        images = Array(repeating: nil, count: vrm.images?.count ?? 0)
    }

    func load<T>(_ keyPath: KeyPath<SceneData, [T]>, index: Int) throws -> T {
        let values = self[keyPath: keyPath]
        return try values[safe: index] ??? ._dataInconsistent("\(keyPath): out of index \(index) < \(values.count)")
    }
}
