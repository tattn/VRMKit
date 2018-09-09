//
//  Buffer.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#buffer

extension GLTF {
    public struct Buffer: Codable {
        public let uri: String?
        public let byteLength: Int
        public let name: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?
    }
}
