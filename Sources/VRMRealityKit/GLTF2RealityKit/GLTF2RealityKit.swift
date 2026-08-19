#if canImport(RealityKit)
import CoreGraphics
import RealityKit
import VRMKit

extension GLTF.Vector3 {
    var simd: SIMD3<Float> {
        SIMD3<Float>(x: x, y: y, z: z)
    }
}

extension GLTF.Vector4 {
    var simdQuat: simd_quatf {
        if x == 0 && y == 0 && z == 0 && w == 0 {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
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

extension GLTF.Color4 {
    var vrmColor: VRMColor {
        VRMColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}
#endif
