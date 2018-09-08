//
//  Color3.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

public struct Color3: Codable {
    public let r, g, b: Float

    public static var black: Color3 {
        return .init(r: 0, g: 0, b: 0)
    }
}

extension Color3 {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        r = try container.decode(Float.self)
        g = try container.decode(Float.self)
        b = try container.decode(Float.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(r)
        try container.encode(g)
        try container.encode(b)
    }
}
