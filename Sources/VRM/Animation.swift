//
//  Animation.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#animation

extension GLTF {
    public struct Animation: Codable {
        public let channels: [Channel]
        public let samplers: [Sampler]
        public let name: String?
        public let extensions: Extensions?
        public let extras: Extensions?

        public struct Channel: Codable {
            let sampler: Int
            let target: Target
            let extensions: Extensions?
            let extras: Extensions?

            public struct Target: Codable {
                let node: Int?
                let path: String
                let extensions: Extensions?
                let extras: Extensions?
            }
        }

        public struct Sampler: Codable {
            let input: Int
            let _interpolation: Interpolation?
            var interpolation: Interpolation { return _interpolation ?? .LINEAR }
            let output: Int
            let extensions: Extensions?
            let extras: Extensions?
            private enum CodingKeys: String, CodingKey {
                case input
                case _interpolation = "interpolation"
                case output
                case extensions
                case extras
            }

            public enum Interpolation: String, Codable {
                case LINEAR
                case STEP
                case CUBICSPLINE
            }
        }
    }
}
