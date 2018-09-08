//
//  Camera.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#camera

extension GLTF {
    public struct Camera: Codable {
        public let orthographic: Orthographic?
        public let perspective: Perspective?
        public let type: Type
        public let name: String?
        public let extensions: Extensions?
        public let extras: Extensions?

        public struct Orthographic: Codable {
            let xmag: Float
            let ymag: Float
            let zfar: Float
            let znear: Float
            let extensions: Extensions?
            let extras: Extensions?
        }

        public struct Perspective: Codable {
            let aspectRatio: Float?
            let yfov: Float
            let zfar: Float?
            let znear: Float
            let extensions: Extensions?
            let extras: Extensions?
        }

        public enum `Type`: String, Codable {
            case perspective
            case orthographic
        }
    }
}
