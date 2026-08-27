import CoreGraphics
import Foundation

package extension GLTFDocument {
    /// The image at `index` decoded, out of a buffer view, a file or a data URI.
    ///
    /// A `CGImage`, so that parsing a glTF needs no UI framework. Each renderer
    /// wraps it in whatever its own texture API asks for.
    func image(at index: Int) throws -> CGImage {
        let image = try gltf.load(\.images, at: index)
        let data: Data
        if let uri = image.uri {
            data = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let bufferView = image.bufferView {
            data = try bufferViewData(at: bufferView).data
        } else {
            throw VRMError._dataInconsistent("the image names neither a uri nor a buffer view")
        }
        return try data.decodedImage ??? ._dataInconsistent("the image is of no format this platform decodes")
    }
}
