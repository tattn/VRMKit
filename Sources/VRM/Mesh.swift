//
//  Mesh.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#mesh

extension GLTF {
    public struct Mesh: Codable {
        public let primitives: [Primitive]
        public let weights: [Float]?
        public let name: String?
        public let extensions: Extensions?
        public let extras: Extensions?

        public struct Primitive: Codable {
            public let attributes: CodableDictionary<AttributeKey, Int>
            public let indices: Int?
            public let material: Int?
            let _mode: Mode?
            public var mode: Mode { return _mode ?? .TRIANGLES }
            public let targets: [[String: TargetValue]]?
            public let extensions: Extensions?
            public let extras: Extensions?
            private enum CodingKeys: String, CodingKey {
                case attributes
                case indices
                case material
                case _mode = "mode"
                case targets
                case extensions
                case extras
            }

            public enum Mode: Int, Codable {
                case POINTS
                case LINES
                case LINE_LOOP
                case LINE_STRIP
                case TRIANGLES
                case TRIANGLE_STRIP
                case TRIANGLE_FAN
            }

            public enum AttributeKey: String, CodingKey {
                case POSITION
                case NORMAL
                case TANGENT
                case TEXCOORD_0
                case TEXCOORD_1
                case COLOR_0
                case JOINTS_0
                case WEIGHTS_0
            }

            public enum TargetValue: Codable {
                case dictionary([String: String])
                case int(Int)

                public func encode(to encoder: Encoder) throws {
                    switch self {
                    case .int(let value):
                        var container = encoder.singleValueContainer()
                        try container.encode(value)
                    case .dictionary(let value):
                        var container = encoder.singleValueContainer()
                        try container.encode(value)
                    }
                }

                public init(from decoder: Decoder) throws {
                    do {
                        let container = try decoder.singleValueContainer()
                        self = .int(try container.decode(Int.self))
                    } catch {
                        let container = try decoder.singleValueContainer()
                        self = .dictionary(try container.decode([String: String].self))
                    }
                }
            }
        }
    }
}
