//
//  Node.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#node

extension GLTF {
    public struct Node: Codable {
        public let camera: Int?
        public let children: [Int]?
        public let skin: Int?
        public let _matrix: Matrix?
        public var matrix: Matrix {
            return self._matrix ?? .identity
        }
        public let mesh: Int?
        let _rotation: Vector4?
        public var rotation: Vector4 {
            return self._rotation ?? .zero
        }
        let _scale: Vector3?
        public var scale: Vector3 {
            return self._scale ?? .one
        }
        let _translation: Vector3?
        public var translation: Vector3 {
            return self._translation ?? .zero
        }
        public let weights: [Float]?
        public let name: String?
        public let extensions: CodableAny?
        public let extras: CodableAny?

        private enum CodingKeys: String, CodingKey {
            case camera
            case children
            case skin
            case _matrix = "matrix"
            case mesh
            case _rotation = "rotation"
            case _scale = "scale"
            case _translation = "translation"
            case weights
            case name
            case extensions
            case extras
        }
    }
}
