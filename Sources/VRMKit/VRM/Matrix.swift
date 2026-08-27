import Foundation

extension GLTF {
    public struct Matrix: Codable, Sendable {
        /// The 16 values of a 4x4 matrix, in glTF's column-major order.
        public let values: [Float]

        public static var identity: Matrix {
            return .init(values: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        }
    }
}

extension GLTF.Matrix {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Float] = []
        values.reserveCapacity(container.count ?? 16)
        while !container.isAtEnd {
            values.append(try container.decode(Float.self))
        }
        // Every reader indexes all 16, so a short one throws instead of trapping.
        guard values.count == 16 else {
            throw VRMError._dataInconsistent("a glTF matrix has 16 values, got \(values.count)")
        }
        self.values = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in values {
            try container.encode(value)
        }
    }
}
