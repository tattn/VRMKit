//
//  BufferView.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#bufferview

extension GLTF {
    public struct BufferView: Codable {
        public let buffer: Int
        let _byteOffset: Int?
        public var byteOffset: Int { return _byteOffset ?? 0 }
        public let byteLength: Int
        public let byteStride: Int?
        public let target: Int?
        public let name: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?
        private enum CodingKeys: String, CodingKey {
            case buffer
            case _byteOffset = "byteOffset"
            case byteLength
            case byteStride
            case target
            case name
            case extensions
            case extras
        }
    }
}
