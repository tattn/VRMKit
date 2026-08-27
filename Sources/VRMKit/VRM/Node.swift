import Foundation
import simd

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#node

extension GLTF {
    public struct Node: Codable, Sendable {
        public let camera: Int?
        public let children: [Int]?
        public let skin: Int?
        public let matrix: Matrix?
        public let mesh: Int?
        let _rotation: SIMD4<Float>?
        public var rotation: SIMD4<Float> {
            _rotation ?? SIMD4<Float>(0, 0, 0, 1)
        }
        let _scale: SIMD3<Float>?
        public var scale: SIMD3<Float> {
            _scale ?? SIMD3<Float>(repeating: 1)
        }
        let _translation: SIMD3<Float>?
        public var translation: SIMD3<Float> {
            _translation ?? .zero
        }
        public let weights: [Float]?
        public let name: String?
        public let extensions: NodeExtensions?
        public let extras: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case camera
            case children
            case skin
            case matrix
            case mesh
            case _rotation = "rotation"
            case _scale = "scale"
            case _translation = "translation"
            case weights
            case name
            case extensions
            case extras
        }

        public struct NodeExtensions: Codable, Sendable {
            /// Every extension on the node as the document wrote it, the modeled ones
            /// included, so an unmodeled one is still readable.
            public let raw: [String: JSONValue]
            public let nodeConstraint: NodeConstraint?

            /// The extension named `name`, as it was written.
            public subscript(name: String) -> JSONValue? { raw[name] }

            public init(from decoder: Decoder) throws {
                raw = try JSONValue(from: decoder).objectValue ?? [:]
                nodeConstraint = try raw[GLTFExtension.nodeConstraint.rawValue]?.decode(NodeConstraint.self)
            }

            public func encode(to encoder: Encoder) throws {
                try JSONValue.object(raw).encode(to: encoder)
            }

            public struct NodeConstraint: Codable, Sendable {
                /// The `VRMC_node_constraint` spec versions this type models.
                public static func supports(specVersion: String?) -> Bool {
                    specVersion == "1.0" || specVersion == "1.0-beta"
                }

                public let specVersion: String?
                /// The constraint, or nil for a spec version this package does not model:
                /// the node goes unconstrained, and what the document wrote still travels
                /// in the raw JSON.
                public let constraint: Constraint?
                public let extensions: JSONValue?
                public let extras: JSONValue?

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    specVersion = try container.decodeIfPresent(String.self, forKey: .specVersion)
                    constraint = Self.supports(specVersion: specVersion)
                        ? try container.decode(Constraint.self, forKey: .constraint)
                        : nil
                    extensions = try container.decodeIfPresent(JSONValue.self, forKey: .extensions)
                    extras = try container.decodeIfPresent(JSONValue.self, forKey: .extras)
                }

                /// How a node is driven by another's transform. The extension defines exactly
                /// one per constraint, so naming none or several is refused.
                public enum Constraint: Codable, Sendable {
                    case roll(RollConstraint)
                    case aim(AimConstraint)
                    case rotation(RotationConstraint)

                    private enum CodingKeys: String, CodingKey {
                        case roll, aim, rotation
                    }

                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        let constraints: [Constraint] = [
                            try container.decodeIfPresent(RollConstraint.self, forKey: .roll).map(Constraint.roll),
                            try container.decodeIfPresent(AimConstraint.self, forKey: .aim).map(Constraint.aim),
                            try container.decodeIfPresent(RotationConstraint.self, forKey: .rotation).map(Constraint.rotation),
                        ].compactMap { $0 }
                        guard constraints.count == 1, let constraint = constraints.first else {
                            throw VRMError._dataInconsistent(
                                "a VRMC_node_constraint defines one of roll, aim and rotation, "
                                + "and this one holds \(constraints.count)"
                            )
                        }
                        self = constraint
                    }

                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        switch self {
                        case .roll(let constraint): try container.encode(constraint, forKey: .roll)
                        case .aim(let constraint): try container.encode(constraint, forKey: .aim)
                        case .rotation(let constraint): try container.encode(constraint, forKey: .rotation)
                        }
                    }

                    /// The node this one is driven by.
                    public var source: Int {
                        switch self {
                        case .roll(let constraint): constraint.source
                        case .aim(let constraint): constraint.source
                        case .rotation(let constraint): constraint.source
                        }
                    }

                    /// How much of the source's motion is passed on, `1` by default.
                    public var weight: Double {
                        switch self {
                        case .roll(let constraint): constraint.weight ?? 1
                        case .aim(let constraint): constraint.weight ?? 1
                        case .rotation(let constraint): constraint.weight ?? 1
                        }
                    }

                    public struct RollConstraint: Codable, Sendable {
                        public let source: Int
                        public let rollAxis: RollAxis
                        public let weight: Double?
                        public let extensions: JSONValue?
                        public let extras: JSONValue?

                        public enum RollAxis: String, Codable, Sendable {
                            case x = "X"
                            case y = "Y"
                            case z = "Z"
                        }
                    }

                    public struct AimConstraint: Codable, Sendable {
                        public let source: Int
                        public let aimAxis: AimAxis
                        public let weight: Double?
                        public let extensions: JSONValue?
                        public let extras: JSONValue?

                        public enum AimAxis: String, Codable, Sendable {
                            case positiveX = "PositiveX"
                            case negativeX = "NegativeX"
                            case positiveY = "PositiveY"
                            case negativeY = "NegativeY"
                            case positiveZ = "PositiveZ"
                            case negativeZ = "NegativeZ"
                        }
                    }

                    public struct RotationConstraint: Codable, Sendable {
                        public let source: Int
                        public let weight: Double?
                        public let extensions: JSONValue?
                        public let extras: JSONValue?
                    }
                }
            }
        }
    }
}
