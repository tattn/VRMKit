import CoreGraphics
import Foundation

public extension VRM {
    /// The index of the image the model shows itself by.
    ///
    /// The versions keep it in different places: VRM 0.x names a texture that
    /// reads an image, VRM 1.0 names the image outright.
    var thumbnailImageIndex: Int {
        get throws {
            switch self {
            case .v0(let vrm0): try vrm0.thumbnailImageIndex
            case .v1(let vrm1): try vrm1.thumbnailImageIndex
            }
        }
    }

    /// The image the model shows itself by.
    var thumbnail: CGImage {
        get throws { try document.image(at: try thumbnailImageIndex) }
    }
}

public extension VRM0 {
    var thumbnailImageIndex: Int {
        get throws {
            guard let textureIndex = meta.texture, textureIndex >= 0 else {
                throw VRMError.thumbnailNotFound
            }
            let textures = try document.gltf.load(\.textures)
            guard textures.indices.contains(textureIndex) else {
                throw VRMError.thumbnailNotFound
            }
            return try validImageIndex(textures[textureIndex].source)
        }
    }

    var thumbnail: CGImage {
        get throws { try document.image(at: try thumbnailImageIndex) }
    }
}

public extension VRM1 {
    var thumbnailImageIndex: Int {
        get throws {
            guard let imageIndex = meta.thumbnailImage, imageIndex >= 0 else {
                throw VRMError.thumbnailNotFound
            }
            return try validImageIndex(imageIndex)
        }
    }

    var thumbnail: CGImage {
        get throws { try document.image(at: try thumbnailImageIndex) }
    }
}

private extension VRM0 {
    func validImageIndex(_ index: Int) throws -> Int {
        try document.gltf.validThumbnailImageIndex(index)
    }
}

private extension VRM1 {
    func validImageIndex(_ index: Int) throws -> Int {
        try document.gltf.validThumbnailImageIndex(index)
    }
}

private extension GLTF {
    /// An index the document actually holds an image at. A model naming one it
    /// does not carry has no thumbnail rather than a broken one.
    func validThumbnailImageIndex(_ index: Int) throws -> Int {
        let images = try load(\.images)
        guard images.indices.contains(index) else {
            throw VRMError.thumbnailNotFound
        }
        return index
    }
}
