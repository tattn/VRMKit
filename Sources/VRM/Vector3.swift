//
//  Vector3.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

extension GLTF {
    public struct Vector3: Codable {
        public let x, y, z: Float

        public init(x: Float, y: Float, z: Float) {
            self.x = x
            self.y = y
            self.z = z
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            x = try container.decode(Float.self)
            y = try container.decode(Float.self)
            z = try container.decode(Float.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(x)
            try container.encode(y)
            try container.encode(z)
        }
    }
}
