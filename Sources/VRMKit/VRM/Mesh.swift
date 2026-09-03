import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#mesh

extension GLTF {
    public struct Mesh: Codable, Sendable {
        public let primitives: [Primitive]
        public let weights: [Float]?
        public let name: String?
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public struct Primitive: Codable, Sendable {
            public let attributes: [AttributeKey: Int]
            public let indices: Int?
            public let material: Int?
            public let mode: Mode
            public var targets: [[AttributeKey: Int]]?
            public let extensions: JSONValue?
            public let extras: JSONValue?

            public enum Mode: Int, Codable, Sendable {
                case POINTS
                case LINES
                case LINE_LOOP
                case LINE_STRIP
                case TRIANGLES
                case TRIANGLE_STRIP
                case TRIANGLE_FAN
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                attributes = try container.decode([AttributeKey: Int].self, forKey: .attributes)
                indices = try container.decodeIfPresent(Int.self, forKey: .indices)
                material = try container.decodeIfPresent(Int.self, forKey: .material)
                // The spec defaults mode to TRIANGLES only when the key is absent;
                // a value outside 0...6 is malformed, not an omission.
                mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .TRIANGLES
                targets = try container.decodeIfPresent([[AttributeKey: IntOrDictionary]].self, forKey: .targets)?
                    .map {
                        $0.reduce(into: [:], { (result, value) in
                            // A VRM 0.x exporter writes -1 for "no accessor in this
                            // target", and objects where an index belongs.
                            guard let intValue = value.value.intValue, intValue >= 0 else { return }
                            result[value.key] = intValue
                        })
                    }
                extensions = try container.decodeIfPresent(JSONValue.self, forKey: .extensions)
                extras = try container.decodeIfPresent(JSONValue.self, forKey: .extras)
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

package extension GLTF.Mesh {
    /// The morph targets each POSITION accessor of this mesh is morphed by.
    ///
    /// Some VRM meshes split their primitives by indices while sharing one
    /// POSITION accessor, and only one of those primitives carries the morph
    /// targets: the rest morph with it.
    func morphTargetsByPositionAccessor() -> [Int: [[Primitive.AttributeKey: Int]]] {
        var shared: [Int: [[Primitive.AttributeKey: Int]]] = [:]
        for primitive in primitives {
            guard let targets = primitive.targets, !targets.isEmpty,
                  let position = primitive.attributes[.POSITION],
                  shared[position] == nil else { continue }
            shared[position] = targets
        }
        return shared
    }
}
