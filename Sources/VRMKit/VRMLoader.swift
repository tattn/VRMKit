import Foundation
#if canImport(SceneKit)
import SceneKit
#endif

open class VRMLoader {
    public init() {}

    open func load(named: String) throws -> VRM {
        guard let url = Bundle.main.url(forResource: named, withExtension: nil) else {
            throw URLError(.fileDoesNotExist)
        }
        return try load(withURL: url)
    }

    open func load(withURL url: URL) throws -> VRM {
        let data = try Data(contentsOf: url)
        return try load(withData: data)
    }

    open func load(withData data: Data) throws -> VRM {
        return try VRM(data: data)
    }

    open func loadThumbnail(from vrm: VRM) throws -> VRMImage {
        guard let textureIndex = vrm.meta.texture, textureIndex >= 0 else {
            throw VRMError.thumbnailNotFound
        }
        return try loadImage(from: vrm.gltf, at: textureIndex)
    }

    open func loadThumbnail(from vrm0: VRM0) throws -> VRMImage {
        guard let textureIndex = vrm0.meta.texture, textureIndex >= 0 else {
            throw VRMError.thumbnailNotFound
        }
        return try loadImage(from: vrm0.gltf, at: textureIndex)
    }

    open func loadThumbnail(from vrm1: VRM1) throws -> VRMImage {
        guard let imageIndex = vrm1.meta.thumbnailImage, imageIndex >= 0 else {
            throw VRMError.thumbnailNotFound
        }
        return try loadImage(from: vrm1.gltf, at: imageIndex)
    }

    private func loadImage(from gltf: BinaryGLTF, at index: Int, relativeTo rootDirectory: URL? = nil) throws -> VRMImage {
        let gltfImage = try gltf.jsonData.load(\.images)[index]
        let imageData: Data
        if let uri = gltfImage.uri {
            imageData = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let bufferViewIndex = gltfImage.bufferView {
            imageData = try gltf.bufferViewData(at: bufferViewIndex).data
        } else {
            throw VRMError._dataInconsistent("Image has neither uri nor bufferView")
        }
        return try VRMImage(data: imageData) ??? ._dataInconsistent("Failed to create image from data")
    }
}
