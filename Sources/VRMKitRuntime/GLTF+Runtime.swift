import VRMKit

package protocol GLTFTextureInfoProtocol {
    var index: Int { get }
    var texCoord: Int { get }
}

extension GLTF.TextureInfo: GLTFTextureInfoProtocol {}
extension GLTF.Material.NormalTextureInfo: GLTFTextureInfoProtocol {}
extension GLTF.Material.OcclusionTextureInfo: GLTFTextureInfoProtocol {}
