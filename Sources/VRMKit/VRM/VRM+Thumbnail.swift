import CoreGraphics
import Foundation

public extension VRM {
    /// The index of the image the model shows itself by.
    ///
    /// The versions keep it in different places: VRM 0.x names a texture that
    /// reads an image, VRM 1.0 names the image outright.
    var thumbnailImageIndex: GLTFImageIndex {
        get throws {
            switch self {
            case .v0(let vrm0): try vrm0.thumbnailImageIndex
            case .v1(let vrm1): try vrm1.thumbnailImageIndex
            }
        }
    }

    /// The image the model shows itself by.
    var thumbnail: CGImage {
        get throws { try document.image(at: try thumbnailImageIndex.rawValue) }
    }
}

public extension VRM0 {
    var thumbnailImageIndex: GLTFImageIndex {
        get throws {
            guard let textureIndex = meta.texture, textureIndex >= 0 else {
                throw VRMError.thumbnailNotFound
            }
            guard let source = document.gltf.textures[safe: textureIndex]?.source else {
                throw VRMError.thumbnailNotFound
            }
            return try document.gltf.validThumbnailImageIndex(source)
        }
    }

    var thumbnail: CGImage {
        get throws { try document.image(at: try thumbnailImageIndex.rawValue) }
    }
}

public extension VRM1 {
    var thumbnailImageIndex: GLTFImageIndex {
        get throws {
            guard let imageIndex = meta.thumbnailImage, imageIndex >= 0 else {
                throw VRMError.thumbnailNotFound
            }
            return try document.gltf.validThumbnailImageIndex(imageIndex)
        }
    }

    var thumbnail: CGImage {
        get throws { try document.image(at: try thumbnailImageIndex.rawValue) }
    }
}

private extension GLTF {
    /// An index the document actually holds an image at, so a model naming one it
    /// does not carry has no thumbnail rather than a broken one.
    func validThumbnailImageIndex(_ index: Int) throws -> GLTFImageIndex {
        guard images.indices.contains(index) else {
            throw VRMError.thumbnailNotFound
        }
        return GLTFImageIndex(index)
    }
}
