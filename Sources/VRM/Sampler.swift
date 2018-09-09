//
//  Sampler.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#sampler

extension GLTF {
    public struct Sampler: Codable {
        public let magFilter: MagFilter?
        public let minFilter: MinFilter?
        let _wrapS: Wrap?
        public var wrapS: Wrap {
            return self._wrapS ?? .REPEAT
        }
        let _wrapT: Wrap?
        public var wrapT: Wrap {
            return self._wrapT ?? .REPEAT
        }
        public let name: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?

        private enum CodingKeys: String, CodingKey {
            case magFilter
            case minFilter
            case _wrapS = "wrapS"
            case _wrapT = "wrapT"
            case name
            case extensions
            case extras
        }

        public enum MagFilter: Int, Codable {
            case NEAREST = 9728
            case LINEAR = 9729
        }

        public enum MinFilter: Int, Codable {
            case NEAREST = 9728
            case LINEAR = 9729
            case NEAREST_MIPMAP_NEAREST = 9984
            case LINEAR_MIPMAP_NEAREST = 9985
            case NEAREST_MIPMAP_LINEAR = 9986
            case LINEAR_MIPMAP_LINEAR = 9987
        }

        public enum Wrap: Int, Codable {
            case CLAMP_TO_EDGE = 33071
            case MIRRORED_REPEAT = 33648
            case REPEAT = 10497
        }
    }
}
