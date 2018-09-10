//
//  GLTF+.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180912.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import Foundation

protocol GLTFTextureInfoProtocol {
    var index: Int { get }
    var texCoord: Int { get }
}

extension GLTF.TextureInfo: GLTFTextureInfoProtocol {}
extension GLTF.Material.NormalTextureInfo: GLTFTextureInfoProtocol {}
extension GLTF.Material.OcclusionTextureInfo: GLTFTextureInfoProtocol {}
