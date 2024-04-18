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
                public let extensions: CodableAny?
                public let extras: CodableAny?

                public struct Constraint: Codable {
                    public let roll: RollConstraint?
                    public let aim: AimConstraint?
                    public let rotation: RotationConstraint?
                    public let extensions: CodableAny?
                    public let extras: CodableAny?

                    public struct RollConstraint: Codable {
                        public let source: Int
                        public let rollAxis: RollAxis
                        public let weight: Double?
                        public let extensions: CodableAny?
                        public let extras: CodableAny?

                        public enum RollAxis: String, Codable {
                            case x
                            case y
                            case z

                            private enum CodingKeys: String, CodingKey {
                                case x = "X"
                                case y = "Y"
                                case z = "Z"
                            }
                        }
                    }

                    public struct AimConstraint: Codable {
                        public let source: Int
                        public let aimAxis: AimAxis
                        public let weight: Double?
                        public let extensions: CodableAny?
                        public let extras: CodableAny?

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
                    }

                    public struct RotationConstraint: Codable {
                        public let source: Int
                        public let weight: Double?
                        public let extensions: CodableAny?
                        public let extras: CodableAny?
                    }
                }
            }
        }
    }
}
