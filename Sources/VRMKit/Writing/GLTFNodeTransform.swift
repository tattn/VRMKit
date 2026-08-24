import Foundation
import simd

/// The local transform of a glTF node, as the translation / rotation / scale
/// triple glTF writes it in. A node carrying a 4x4 `matrix` instead is
/// decomposed, since editing writes TRS back either way.
public struct GLTFNodeTransform: Equatable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>

    public static var identity: GLTFNodeTransform { .init() }

    public init(translation: SIMD3<Float> = .zero,
                rotation: simd_quatf = simd_quatf(vector: SIMD4<Float>(0, 0, 0, 1)),
                scale: SIMD3<Float> = .one) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    /// Decomposes a column-major 4x4 transform. A mirroring matrix has no
    /// rotation of its own, so its negative determinant folds into the scale.
    public init(matrix: float4x4) {
        translation = matrix.translation

        var basis = float3x3(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                             SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                             SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        var scale = SIMD3(simd_length(basis.columns.0),
                          simd_length(basis.columns.1),
                          simd_length(basis.columns.2))
        if basis.determinant < 0 {
            scale.x = -scale.x
        }
        self.scale = scale

        for axis in 0..<3 where scale[axis] != 0 {
            basis[axis] /= scale[axis]
        }
        // A flattened basis has no rotation to recover, and feeding one to
        // `simd_quatf` yields NaNs. Tested axis by axis rather than by `min()`,
        // which a mirroring matrix's negative axis would answer for.
        let isFlattened = scale.x == 0 || scale.y == 0 || scale.z == 0
        rotation = isFlattened ? .identityRotation : simd_quatf(basis)
    }

    public var matrix: float4x4 {
        let basis = float3x3(rotation)
        return float4x4(SIMD4(basis.columns.0 * scale.x, 0),
                        SIMD4(basis.columns.1 * scale.y, 0),
                        SIMD4(basis.columns.2 * scale.z, 0),
                        SIMD4(translation, 1))
    }
}

extension simd_quatf {
    /// The rotation a glTF node has when it writes none.
    static var identityRotation: simd_quatf { .init(vector: SIMD4<Float>(0, 0, 0, 1)) }

    /// The unit quaternion glTF requires. One of no length names no rotation,
    /// so it becomes the identity rather than NaNs.
    var normalizedForGLTF: simd_quatf {
        let length = simd_length(vector)
        guard length.isNormal else { return .identityRotation }
        return simd_quatf(vector: vector / length)
    }
}

extension GLTFNodeTransform {
    /// Rejects values JSON and glTF cannot represent. A finite zero-length
    /// quaternion is still normalized to the identity by ``normalizedForGLTF``.
    func validate() throws {
        let quaternion = rotation.vector
        guard quaternion.x.isFinite, quaternion.y.isFinite,
              quaternion.z.isFinite, quaternion.w.isFinite,
              translation.x.isFinite, translation.y.isFinite, translation.z.isFinite,
              scale.x.isFinite, scale.y.isFinite, scale.z.isFinite else {
            throw VRMError._dataInconsistent("a node transform cannot contain infinity or NaN")
        }
    }

    /// The transform a node JSON object describes, whether it writes TRS or a
    /// matrix. glTF forbids mixing the two, and the matrix wins if one does.
    init(node: JSONObject) {
        if let c = node.floats("matrix"), c.count == 16 {
            self.init(matrix: float4x4(SIMD4(c[0], c[1], c[2], c[3]),
                                       SIMD4(c[4], c[5], c[6], c[7]),
                                       SIMD4(c[8], c[9], c[10], c[11]),
                                       SIMD4(c[12], c[13], c[14], c[15])))
            return
        }
        self.init(translation: Self.vector3(node.floats("translation")) ?? .zero,
                  rotation: Self.vector4(node.floats("rotation")).map(simd_quatf.init(vector:)) ?? .identityRotation,
                  scale: Self.vector3(node.floats("scale")) ?? .one)
    }

    private static func vector3(_ values: [Float]?) -> SIMD3<Float>? {
        guard let values, values.count >= 3 else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    private static func vector4(_ values: [Float]?) -> SIMD4<Float>? {
        guard let values, values.count >= 4 else { return nil }
        return SIMD4(values[0], values[1], values[2], values[3])
    }

    /// Writes the transform into a node object, dropping the `matrix` form and
    /// every component at its default.
    func write(into node: inout JSONObject) {
        node.removeValue(forKey: "matrix")
        node.set("translation", translation == .zero ? nil : [translation.x, translation.y, translation.z])
        let unitRotation = rotation.normalizedForGLTF
        node.set("rotation", unitRotation == .identityRotation
                 ? nil
                 : [unitRotation.vector.x, unitRotation.vector.y, unitRotation.vector.z, unitRotation.vector.w])
        node.set("scale", scale == .one ? nil : [scale.x, scale.y, scale.z])
    }
}
