import Foundation
import simd

/// The local transform of a glTF node, as a translation / rotation / scale triple.
/// A node carrying a 4x4 `matrix` is decomposed, since editing writes TRS back either way.
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

    /// Decomposes a column-major 4x4 transform, folding a mirroring matrix's negative
    /// determinant into the scale.
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
        // A flattened basis has no rotation to recover, and feeding one to `simd_quatf`
        // yields NaNs. Tested axis by axis: `min()` would answer for a mirrored axis.
        let isFlattened = scale.x == 0 || scale.y == 0 || scale.z == 0
        rotation = isFlattened ? quat_identity_float : simd_quatf(basis)
    }

    public var matrix: float4x4 {
        let basis = float3x3(rotation.safelyNormalized)
        return float4x4(SIMD4(basis.columns.0 * scale.x, 0),
                        SIMD4(basis.columns.1 * scale.y, 0),
                        SIMD4(basis.columns.2 * scale.z, 0),
                        SIMD4(translation, 1))
    }
}

extension GLTFNodeTransform {
    /// Rejects values JSON and glTF cannot represent. ``safelyNormalized`` turns a finite
    /// zero-length quaternion into the identity.
    func validate() throws {
        let quaternion = rotation.vector
        guard quaternion.x.isFinite, quaternion.y.isFinite,
              quaternion.z.isFinite, quaternion.w.isFinite,
              translation.x.isFinite, translation.y.isFinite, translation.z.isFinite,
              scale.x.isFinite, scale.y.isFinite, scale.z.isFinite else {
            throw VRMError._invalidArgument("a node transform cannot contain infinity or NaN")
        }
    }

    /// The transform a node JSON object describes, TRS or matrix. glTF forbids mixing
    /// the two, and the matrix wins if one does.
    init(node: JSONObject) {
        if let components = node.floats("matrix"), components.count == 16 {
            self.init(matrix: float4x4(SIMD4(components[0], components[1], components[2], components[3]),
                                       SIMD4(components[4], components[5], components[6], components[7]),
                                       SIMD4(components[8], components[9], components[10], components[11]),
                                       SIMD4(components[12], components[13], components[14], components[15])))
            return
        }
        self.init(translation: Self.vector3(node.floats("translation")) ?? .zero,
                  rotation: Self.vector4(node.floats("rotation")).map(simd_quatf.init(vector:))
                      ?? quat_identity_float,
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

    /// Writes the transform into a node object, dropping the `matrix` form and every
    /// component at its default.
    func write(into node: inout JSONObject) {
        node.removeValue(forKey: "matrix")
        node.set("translation", translation == .zero ? nil : [translation.x, translation.y, translation.z])
        let unitRotation = rotation.safelyNormalized
        node.set("rotation", unitRotation == quat_identity_float
                 ? nil
                 : [unitRotation.vector.x, unitRotation.vector.y, unitRotation.vector.z, unitRotation.vector.w])
        node.set("scale", scale == .one ? nil : [scale.x, scale.y, scale.z])
    }
}
