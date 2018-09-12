//
//  Image.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#image

extension GLTF {
    public struct Image: Codable {
        public let uri: String?
        public let mimeType: String?
        public let bufferView: Int?
        public let name: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?
    }
}
