import VRMKit
import VRMKitRuntime
import SceneKit

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

    func setTextureInfo(_ textureInfo: GLTFTextureInfoProtocol, loader: VRMSceneLoader) throws {
        let texture = try loader.texture(withTextureIndex: textureInfo.index)
        contents = texture.contents
        magnificationFilter = texture.magnificationFilter
        minificationFilter = texture.minificationFilter
        mipFilter = texture.mipFilter
        wrapS = texture.wrapS
        wrapT = texture.wrapT
        intensity = texture.intensity

        mappingChannel = textureInfo.texCoord
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
