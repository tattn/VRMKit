import Foundation
import VRMKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension VRMImage {
    static func from(_ image: GLTF.Image, relativeTo rootDirectory: URL?, loader: VRMSceneLoader) throws -> VRMImage {
        let data: Data
        if let uri = image.uri {
            data = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let bufferViewIndex = image.bufferView {
            data = try loader.bufferView(withBufferViewIndex: bufferViewIndex).bufferView
        } else {
            throw VRMError._dataInconsistent("failed to load images")
        }

        guard let image = VRMImage(data: data) else {
            throw VRMError._dataInconsistent("failed to create image from data")
        }
        return image
    }

}
