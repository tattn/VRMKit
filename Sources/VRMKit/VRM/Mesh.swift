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
        public let extensions: CodableAny?
        public let extras: CodableAny?

        public struct Primitive: Codable {
            public let attributes: CodableDictionary<AttributeKey, Int>
            public let indices: Int?
            public let material: Int?
            public let mode: Mode
            public var targets: [[AttributeKey: Int]]?
            public let extensions: CodableAny?
            public let extras: CodableAny?

            public enum Mode: Int, Codable {
                case POINTS
                case LINES
                case LINE_LOOP
                case LINE_STRIP
                case TRIANGLES
                case TRIANGLE_STRIP
                case TRIANGLE_FAN
            }

            public enum AttributeKey: String, Codable, CodingKey {
                case POSITION
                case NORMAL
                case TANGENT
                case TEXCOORD_0
                case TEXCOORD_1
                case COLOR_0
                case JOINTS_0
                case WEIGHTS_0
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                attributes = try container.decode(CodableDictionary<AttributeKey, Int>.self, forKey: .attributes)
                indices = try container.decodeIfPresent(Int.self, forKey: .indices)
                material = try container.decodeIfPresent(Int.self, forKey: .material)
                mode = (try? container.decode(Mode.self, forKey: .mode)) ?? .TRIANGLES
                targets = try container.decodeIfPresent([CodableDictionary<AttributeKey, IntOrDictionary>].self, forKey: .targets)?
                    .map {
                        $0.rawValue.reduce(into: [:], { (result, value) in
                            // skip extra key (e.g. "extra": { "name": "..." })
                            // skip -1 which means no key
                            guard let intValue = value.value.intValue, intValue >= 0 else { return }
                            result[value.key] = intValue
                        })
                    }
                extensions = try container.decodeIfPresent(CodableAny.self, forKey: .extensions)
                extras = try container.decodeIfPresent(CodableAny.self, forKey: .extras)
            }

            private enum IntOrDictionary: Codable {
                case dictionary([String: String])
                case int(Int)
                var intValue: Int? {
                    switch self {
                    case .dictionary: return nil
                    case .int(let value): return value
                    }
                }

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
                        let value = try container.decode([String: String].self)
                        self = .dictionary(value)
                    }
                }
            }
        }
    }
}
