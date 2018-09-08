//
//  Color4.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

extension GLTF {
    public struct Color4: Codable {
        public let r, g, b, a: Float

        public init(r: Float, g: Float, b: Float, a: Float) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            r = try container.decode(Float.self)
            g = try container.decode(Float.self)
            b = try container.decode(Float.self)
            a = try container.decode(Float.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(r)
            try container.encode(g)
            try container.encode(b)
            try container.encode(a)
        }
    }
}
