//
//  Asset.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#asset-1

extension GLTF {
    public struct Asset: Codable {
        public let copyright: String?
        public let generator: String?
        public let version: String
        public let minVersion: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?
    }
}
