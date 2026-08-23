import Foundation

package extension GLTFDocument {
    /// The image at `index` decoded, out of a buffer view, a file or a data URI.
    func image(at index: Int) throws -> VRMImage {
        let image = try gltf.load(\.images, at: index)
        let data: Data
        if let uri = image.uri {
            data = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let bufferView = image.bufferView {
            data = try bufferViewData(at: bufferView).data
        } else {
            throw VRMError._dataInconsistent("the image names neither a uri nor a buffer view")
        }
        return try VRMImage(data: data) ??? ._dataInconsistent("the image is of no format this platform decodes")
    }
}
