#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

package extension GLTFDocument {
    /// The bytes the image at `index` is stored as, out of a buffer view, a file or a data URI.
    func imageData(at index: Int) throws -> Data {
        let image = try gltf.load(\.images, at: index)
        if let uri = image.uri {
            return try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let bufferView = image.bufferView {
            return try bufferViewData(at: bufferView).data
        } else {
            throw VRMError._dataInconsistent("the image names neither a uri nor a buffer view")
        }
    }

#if canImport(CoreGraphics)
    /// The image at `index` decoded.
    ///
    /// A `CGImage`, so that parsing a glTF needs no UI framework. Each renderer
    /// wraps it in whatever its own texture API asks for.
    func image(at index: Int) throws -> CGImage {
        try imageData(at: index).decodedImage
            ??? ._dataInconsistent("the image is of no format this platform decodes")
    }
#endif
}
