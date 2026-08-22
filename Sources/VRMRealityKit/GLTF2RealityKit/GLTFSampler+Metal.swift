#if canImport(Metal)
import Metal
import VRMKit

extension GLTF.Sampler.MagFilter {
    var metalFilter: MTLSamplerMinMagFilter {
        switch self {
        case .NEAREST: return .nearest
        case .LINEAR: return .linear
        }
    }
}

extension GLTF.Sampler.MinFilter {
    /// glTF's `minFilter` encodes both the minification texel filter and the
    /// mip filter, which Metal keeps separate.
    var metalFilters: (min: MTLSamplerMinMagFilter, mip: MTLSamplerMipFilter) {
        switch self {
        case .NEAREST:
            return (.nearest, .notMipmapped)
        case .LINEAR:
            return (.linear, .notMipmapped)
        case .NEAREST_MIPMAP_NEAREST:
            return (.nearest, .nearest)
        case .LINEAR_MIPMAP_NEAREST:
            return (.linear, .nearest)
        case .NEAREST_MIPMAP_LINEAR:
            return (.nearest, .linear)
        case .LINEAR_MIPMAP_LINEAR:
            return (.linear, .linear)
        }
    }
}

extension GLTF.Sampler.Wrap {
    var metalAddressMode: MTLSamplerAddressMode {
        switch self {
        case .CLAMP_TO_EDGE: return .clampToEdge
        case .MIRRORED_REPEAT: return .mirrorRepeat
        case .REPEAT: return .repeat
        }
    }
}
#endif
