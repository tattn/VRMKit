#if canImport(RealityKit)
import CoreGraphics
import RealityKit
import VRMKit
import VRMKitRuntime

extension SIMD4 where Scalar == Float {
    /// glTF requires a unit quaternion, so an off-unit one is renormalized and a
    /// degenerate one falls back to identity instead of collapsing the node.
    var simdQuat: simd_quatf {
        simd_quatf(ix: x, iy: y, iz: z, r: w).safelyNormalized
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTF.Node {
    /// The node's local transform: its `matrix` when it has one, the TRS
    /// properties otherwise, as the spec defines the two as alternatives.
    var localTransform: Transform {
        if let matrix {
            return Transform(matrix: matrix.simdMatrix)
        }
        return Transform(scale: scale, rotation: rotation.simdQuat, translation: translation)
    }
}

extension GLTF.Matrix {
    var simdMatrix: simd_float4x4 {
        let v = values
        return simd_float4x4(columns: (
            SIMD4<Float>(v[0], v[1], v[2], v[3]),
            SIMD4<Float>(v[4], v[5], v[6], v[7]),
            SIMD4<Float>(v[8], v[9], v[10], v[11]),
            SIMD4<Float>(v[12], v[13], v[14], v[15])
        ))
    }
}

extension Array where Element == GLTFSampledTexture {
    /// Why these textures cannot all draw through the one UV set and one UV transform
    /// RealityKit gives a material, or nil when they can.
    func textureTransformConflict(selectedTexCoord: Int) -> String? {
        guard allSatisfy({ $0.texCoord == selectedTexCoord }) else {
            return "samples UV sets other than \(selectedTexCoord)"
        }
        let transforms = map { $0.transform ?? GLTFUVTransform() }
        guard transforms.allSatisfy({ $0 == transforms.first }) else {
            return "gives its textures different transforms"
        }
        return nil
    }
}

/// The glTF alpha-mode → RealityKit blending decision, shared by every
/// material path: the built-in Unlit / PBR one and MToon's `CustomMaterial`.
struct GLTFAlphaModeSettings {
    let isTransparent: Bool
    let opacityThreshold: Float?

    init(_ mode: GLTF.Material.AlphaMode, alphaCutoff: Float) {
        switch mode {
        case .OPAQUE:
            (isTransparent, opacityThreshold) = (false, nil)
        case .MASK:
            (isTransparent, opacityThreshold) = (false, alphaCutoff)
        case .BLEND:
            (isTransparent, opacityThreshold) = (true, nil)
        }
    }
}
#endif
