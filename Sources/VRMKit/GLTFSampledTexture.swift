import Foundation
import simd

/// `KHR_texture_transform`-style UV transform (glTF top-left origin).
package struct GLTFUVTransform: Equatable, Sendable {
    package let scale: SIMD2<Float>
    package let offset: SIMD2<Float>
    package let rotation: Float

    package init(scale: SIMD2<Float> = SIMD2<Float>(1, 1),
                 offset: SIMD2<Float> = SIMD2<Float>(0, 0),
                 rotation: Float = 0) {
        self.scale = scale
        self.offset = offset
        self.rotation = rotation
    }
}

/// How a material samples one texture through mesh UVs: which texture, which UV
/// set, and the UV transform, with `KHR_texture_transform` decoded.
package struct GLTFSampledTexture: Equatable, Sendable {
    package let index: Int
    /// UV set this texture samples, honoring a `KHR_texture_transform` override.
    package let texCoord: Int
    /// UV transform carried by the source format (`KHR_texture_transform` for
    /// glTF / VRM 1.0, the Unity `_MainTex` scale/offset for VRM 0.x).
    package let transform: GLTFUVTransform?

    package init(index: Int, texCoord: Int = 0, transform: GLTFUVTransform? = nil) {
        self.index = index
        self.texCoord = texCoord
        self.transform = transform
    }

    /// Builds a texture reference from a glTF texture info, decoding
    /// `KHR_texture_transform` and its optional `texCoord` override.
    package init(index: Int, texCoord: Int, extensions: JSONValue?) {
        guard let transform = extensions?.dictionaryValue[GLTFExtension.textureTransform.rawValue]?.objectValue else {
            self.init(index: index, texCoord: texCoord)
            return
        }
        self.init(index: index,
                  texCoord: transform.index("texCoord") ?? texCoord,
                  transform: .init(scale: transform.simd2Value(forKey: "scale", default: SIMD2<Float>(1, 1)),
                                   offset: transform.simd2Value(forKey: "offset", default: SIMD2<Float>(0, 0)),
                                   rotation: transform.float("rotation") ?? 0))
    }

    package init(_ textureInfo: GLTF.TextureInfo) {
        self.init(index: textureInfo.index, texCoord: textureInfo.texCoord, extensions: textureInfo.extensions)
    }

    package init(_ textureInfo: GLTF.Material.NormalTextureInfo) {
        self.init(index: textureInfo.index, texCoord: textureInfo.texCoord, extensions: textureInfo.extensions)
    }

    package init(_ textureInfo: GLTF.Material.OcclusionTextureInfo) {
        self.init(index: textureInfo.index, texCoord: textureInfo.texCoord, extensions: textureInfo.extensions)
    }

    package init(_ textureInfo: GLTF.Material.MaterialExtensions.MaterialsMToon.MaterialsMToonTextureInfo) {
        self.init(index: textureInfo.index, texCoord: textureInfo.texCoord ?? 0, extensions: textureInfo.extensions)
    }

    package init(_ textureInfo: GLTF.Material.MaterialExtensions.MaterialsMToon.MaterialsMToonShadingShiftTexture) {
        self.init(index: textureInfo.index, texCoord: textureInfo.texCoord ?? 0, extensions: textureInfo.extensions)
    }
}

package extension GLTFSampledTexture {
    /// The glTF `textureInfo` naming this texture, the inverse of
    /// ``init(index:texCoord:extensions:)``. An identity transform is left out
    /// so that reading it back gives no transform rather than a no-op one.
    func textureInfo() -> JSONObject {
        var info: JSONObject = ["index": .int(index)]
        info.setNonZero("texCoord", texCoord)
        guard needsTextureTransform, let transform else { return info }
        var textureTransform = JSONObject()
        textureTransform["scale"] = .numbers([transform.scale.x, transform.scale.y])
        textureTransform["offset"] = .numbers([transform.offset.x, transform.offset.y])
        if transform.rotation != 0 {
            textureTransform["rotation"] = .number(transform.rotation)
        }
        info["extensions"] = [GLTFExtension.textureTransform.rawValue: .object(textureTransform)]
        return info
    }

    /// Whether writing the texture needs `KHR_texture_transform`.
    var needsTextureTransform: Bool {
        transform != nil && transform != GLTFUVTransform()
    }
}
