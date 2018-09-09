//
//  Accessor.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#accessor

extension GLTF {
    public struct Accessor: Codable {
        public let bufferView: Int?
        let _byteOffset: Int?
        public var byteOffset: Int { return _byteOffset ?? 0 }
        public let componentType: ComponentType
        let _normalized: Bool?
        public var normalized: Bool { return _normalized ?? false }
        public let count: Int
        public let type: Type
        public let max: [Float]?
        public let min: [Float]?
        public let sparse: Sparse?
        public let name: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?

        private enum CodingKeys: String, CodingKey {
            case bufferView
            case _byteOffset = "byteOffset"
            case componentType
            case _normalized = "normalized"
            case count
            case type
            case max
            case min
            case sparse
            case name
            case extensions
            case extras
        }
    }
}

extension GLTF.Accessor {
    public enum ComponentType: Int, Codable {
        case byte = 5120
        case unsignedByte = 5121
        case short = 5122
        case unsignedShort = 5123
        case unsignedInt = 5125
        case float = 5126
    }

    public enum `Type`: String, Codable {
        case SCALAR
        case VEC2
        case VEC3
        case VEC4
        case MAT2
        case MAT3
        case MAT4
    }

    public struct Sparse: Codable {
        public let count: Int
        public let indices: Indices
        public let values: Values
        public let extensions: CodableAny?
        public let extras: CodableAny?

        public struct Indices: Codable {
            public let bufferView: Int
            let _byteOffset: Int?
            public var byteOffset: Int { return _byteOffset ?? 0 }
            public let componentType: ComponentType
            public let extensions: CodableAny?
            public let extras: CodableAny?
            private enum CodingKeys: String, CodingKey {
                case bufferView
                case _byteOffset = "byteOffset"
                case componentType
                case extensions
                case extras
            }
        }

        public struct Values: Codable {
            public let bufferView: Int
            let _byteOffset: Int?
            public var byteOffset: Int { return _byteOffset ?? 0 }
            public let extensions: CodableAny?
            public let extras: CodableAny?
            private enum CodingKeys: String, CodingKey {
                case bufferView
                case _byteOffset = "byteOffset"
                case extensions
                case extras
            }
        }
    }
}
