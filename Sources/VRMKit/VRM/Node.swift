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
        public let extensions: NodeExtensions?
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

        public struct NodeExtensions: Codable {
            public let nodeConstraint: NodeConstraint?

            private enum CodingKeys: String, CodingKey {
                case nodeConstraint = "VRMC_node_constraint"
            }

            public struct NodeConstraint: Codable {
                public let specVersion: String
                public let constraint: Constraint

                public struct Constraint: Codable {
                    public let roll: RollConstraint?
                    public let aim: AimConstraint?
                    public let rotation: RotationConstraint?

                    public struct RollConstraint: Codable {
                        public let source: Int
                        public let rollAxis: RollAxis
                        public let weight: Double?

                        public enum RollAxis: String, Codable {
                            case X
                            case Y
                            case Z
                        }

                        public init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            source = try container.decode(Int.self, forKey: .source)
                            rollAxis = try container.decode(RollAxis.self, forKey: .rollAxis)
                            weight = try? decodeDouble(key: .weight, container: container)
                        }
                    }

                    public struct AimConstraint: Codable {
                        public let source: Int
                        public let aimAxis: AimAxis
                        public let weight: Double?

                        public enum AimAxis: String, Codable {
                            case positiveX
                            case negativeX
                            case positiveY
                            case negativeY
                            case positiveZ
                            case negativeZ

                            private enum CodingKeys: String, CodingKey {
                                case positiveX = "PositiveX"
                                case negativeX = "NegativeX"
                                case positiveY = "PositiveY"
                                case negativeY = "NegativeY"
                                case positiveZ = "PositiveZ"
                                case negativeZ = "NegativeZ"
                            }
                        }

                        public init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            source = try container.decode(Int.self, forKey: .source)
                            aimAxis = try container.decode(AimAxis.self, forKey: .aimAxis)
                            weight = try? decodeDouble(key: .weight, container: container)
                        }
                    }

                    public struct RotationConstraint: Codable {
                        public let source: Int
                        public let weight: Double?

                        public init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            source = try container.decode(Int.self, forKey: .source)
                            weight = try? decodeDouble(key: .weight, container: container)
                        }
                    }
                }
            }
        }
    }
}
