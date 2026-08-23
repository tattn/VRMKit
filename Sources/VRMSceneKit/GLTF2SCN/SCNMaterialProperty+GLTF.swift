import VRMKit
import SceneKit
import simd

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNMaterialProperty {
    func setSampler(_ sampler: GLTF.Sampler) {
        if let magFilter = sampler.magFilter {
            magnificationFilter = filterMode(of: magFilter)
        }

        if let minFilter = sampler.minFilter {
            (minificationFilter, mipFilter) = filterModes(of: minFilter)
        }

        wrapS = wrapMode(of: sampler.wrapS)
        wrapT = wrapMode(of: sampler.wrapT)
    }

    /// Points this property at the image `texture` names, through the UV set and
    /// the `KHR_texture_transform` it carries. Every texture slot of a glTF
    /// material and of the extensions on it goes through here.
    func setTexture(_ texture: GLTFSampledTexture, loader: VRMSceneLoader) throws {
        let source = try loader.texture(withTextureIndex: texture.index)
        contents = source.contents
        magnificationFilter = source.magnificationFilter
        minificationFilter = source.minificationFilter
        mipFilter = source.mipFilter
        wrapS = source.wrapS
        wrapT = source.wrapT
        intensity = source.intensity

        mappingChannel = texture.texCoord
        if let transform = texture.transform {
            contentsTransform = SCNMatrix4(uvTransform: transform)
        }
    }

    private func filterMode(of filter: GLTF.Sampler.MagFilter) -> SCNFilterMode {
        switch filter {
        case .NEAREST: return .nearest
        case .LINEAR: return .linear
        }
    }

    private func filterModes(of minFilter: GLTF.Sampler.MinFilter) -> (minFilter: SCNFilterMode, mipFilter: SCNFilterMode) {
        switch minFilter {
        case .NEAREST: return (.nearest, .none)
        case .LINEAR: return (.linear, .none)
        case .NEAREST_MIPMAP_NEAREST: return (.nearest, .nearest)
        case .LINEAR_MIPMAP_NEAREST: return (.linear, .nearest)
        case .NEAREST_MIPMAP_LINEAR: return (.nearest, .linear)
        case .LINEAR_MIPMAP_LINEAR: return (.linear, .linear)
        }
    }

    private func wrapMode(of wrap: GLTF.Sampler.Wrap) -> SCNWrapMode {
        switch wrap {
        case .CLAMP_TO_EDGE: return .clamp
        case .MIRRORED_REPEAT: return .mirror
        case .REPEAT: return .repeat
        }
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
private extension SCNMatrix4 {
    /// A `KHR_texture_transform` as a texture coordinate transform.
    ///
    /// The extension composes translation * rotation * scale onto the UV, in
    /// the same top-left origin the geometry's UVs are handed to SceneKit in,
    /// so the columns below are that composition written out.
    init(uvTransform transform: GLTFUVTransform) {
        let (sine, cosine) = (sin(transform.rotation), cos(transform.rotation))
        let scale = transform.scale
        let offset = transform.offset
        self.init(simd_float4x4(columns: (SIMD4<Float>(scale.x * cosine, -scale.x * sine, 0, 0),
                                          SIMD4<Float>(scale.y * sine, scale.y * cosine, 0, 0),
                                          SIMD4<Float>(0, 0, 1, 0),
                                          SIMD4<Float>(offset.x, offset.y, 0, 1))))
    }
}
