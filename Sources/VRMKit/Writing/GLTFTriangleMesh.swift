#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SIMDCompat

/// The vertex data of one indexed triangle mesh, as
/// ``GLTFEditableDocument/addMesh(_:under:name:transform:materials:)`` writes it.
///
/// Anything richer is authored elsewhere and brought in with
/// ``GLTFEditableDocument/append(_:under:name:transform:materials:)``.
public struct GLTFTriangleMesh: Equatable, Sendable {
    public var positions: [SIMD3<Float>]

    /// One unit vector per position, or none to leave the mesh flat-shaded.
    public var normals: [SIMD3<Float>]?

    /// One per position, in glTF's convention: `v` grows downwards from the top edge
    /// of the image. A material showing an image needs them.
    public var textureCoordinates: [SIMD2<Float>]?

    /// Three into `positions` per triangle, wound counter-clockwise seen from the front.
    public var indices: [UInt32]

    /// None leaves the shading to the renderer's default.
    public var material: GLTFSimpleMaterial?

    public init(positions: [SIMD3<Float>],
                normals: [SIMD3<Float>]? = nil,
                textureCoordinates: [SIMD2<Float>]? = nil,
                indices: [UInt32],
                material: GLTFSimpleMaterial? = nil) {
        self.positions = positions
        self.normals = normals
        self.textureCoordinates = textureCoordinates
        self.indices = indices
        self.material = material
    }
}

/// What a texture coordinate outside `[0, 1]` samples, and how the image is filtered.
/// The defaults are glTF's own, so a sampler left alone is not written at all.
public struct GLTFTextureSampler: Hashable, Sendable {
    public var wrapS: GLTF.Sampler.Wrap

    public var wrapT: GLTF.Sampler.Wrap

    /// Nil leaves the choice to the renderer, as glTF does for a sampler naming no filter.
    public var magFilter: GLTF.Sampler.MagFilter?

    public var minFilter: GLTF.Sampler.MinFilter?

    public init(wrapS: GLTF.Sampler.Wrap = .REPEAT,
                wrapT: GLTF.Sampler.Wrap = .REPEAT,
                magFilter: GLTF.Sampler.MagFilter? = nil,
                minFilter: GLTF.Sampler.MinFilter? = nil) {
        self.wrapS = wrapS
        self.wrapT = wrapT
        self.magFilter = magFilter
        self.minFilter = minFilter
    }
}

/// The part of a glTF material an authored mesh needs: a base color, and how its alpha
/// is read. Toon shading goes through `addMesh`'s `materials` parameter instead.
public struct GLTFSimpleMaterial: Equatable, Sendable {
    /// How the renderer reads the alpha of the base color.
    public enum AlphaMode: Equatable, Sendable {
        /// Alpha is ignored and the surface is drawn opaque.
        case opaque
        /// A fragment below `cutoff` is not drawn, one above it fully opaque.
        case mask(cutoff: Float)
        /// Alpha blends the surface over what is behind it.
        case blend
    }

    public var name: String?

    /// The linear color the base color texture, if any, is multiplied by.
    public var baseColorFactor: SIMD4<Float>

    /// A PNG or a JPEG, the two formats a glTF image may hold. Anything else is refused.
    public var baseColorImage: Data?

    /// A plate showing one picture wants `CLAMP_TO_EDGE` rather than glTF's default tiling.
    public var baseColorSampler: GLTFTextureSampler

    /// The linear color the surface gives off whatever lights it, multiplied by the
    /// emissive texture, if any. Black, glTF's default, gives off nothing.
    public var emissiveFactor: SIMD3<Float>

    /// A PNG or a JPEG, as `baseColorImage` is. It shows only through a factor above black.
    public var emissiveImage: Data?

    public var emissiveSampler: GLTFTextureSampler

    /// Shades the surface with its base color alone, through `KHR_materials_unlit`.
    public var isUnlit: Bool

    public var alphaMode: AlphaMode

    /// Draws the back faces too, which a plate seen from either side needs.
    public var isDoubleSided: Bool

    public init(name: String? = nil,
                baseColorFactor: SIMD4<Float> = SIMD4(1, 1, 1, 1),
                baseColorImage: Data? = nil,
                baseColorSampler: GLTFTextureSampler = .init(),
                emissiveFactor: SIMD3<Float> = .zero,
                emissiveImage: Data? = nil,
                emissiveSampler: GLTFTextureSampler = .init(),
                isUnlit: Bool = false,
                alphaMode: AlphaMode = .opaque,
                isDoubleSided: Bool = false) {
        self.name = name
        self.baseColorFactor = baseColorFactor
        self.baseColorImage = baseColorImage
        self.baseColorSampler = baseColorSampler
        self.emissiveFactor = emissiveFactor
        self.emissiveImage = emissiveImage
        self.emissiveSampler = emissiveSampler
        self.isUnlit = isUnlit
        self.alphaMode = alphaMode
        self.isDoubleSided = isDoubleSided
    }
}

struct ValidatedTriangleMesh {
    let positionBounds: (min: [Float], max: [Float])
    let maximumIndex: UInt32
    let imageMediaTypes: GLTFSimpleMaterial.ImageMediaTypes
}

extension GLTFTriangleMesh {
    /// Checked before any of the mesh is written, so a mesh glTF cannot describe leaves
    /// the document alone rather than half written into it.
    func validate() throws -> ValidatedTriangleMesh {
        guard !positions.isEmpty else {
            throw VRMError._invalidArgument("a mesh needs at least one vertex, and this one has no positions")
        }
        var minimum = positions[0]
        var maximum = positions[0]
        for position in positions {
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                throw VRMError._invalidArgument("positions cannot contain infinity or NaN")
            }
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        try validateAttribute(normals, named: "normals")
        try validateNormalsAreUnit()
        try validateAttribute(textureCoordinates, named: "textureCoordinates")

        guard !indices.isEmpty else {
            throw VRMError._invalidArgument("a mesh needs at least one triangle, and this one has no indices")
        }
        guard indices.count % 3 == 0 else {
            throw VRMError._invalidArgument(
                "\(indices.count) indices are not a whole number of triangles"
            )
        }
        let maximumIndex = indices.max()!
        if Int(maximumIndex) >= positions.count {
            throw VRMError._invalidArgument(
                "index \(maximumIndex) is out of range for the \(positions.count) vertices of the mesh"
            )
        }

        let imageMediaTypes = try material?.validate() ?? .init()
        // A texture naming no `texCoord` is read at `TEXCOORD_0`.
        guard imageMediaTypes.isEmpty || textureCoordinates != nil else {
            throw VRMError._invalidArgument(
                "a material with an image needs the texture coordinates to read it at"
            )
        }
        return ValidatedTriangleMesh(
            positionBounds: ([minimum.x, minimum.y, minimum.z], [maximum.x, maximum.y, maximum.z]),
            maximumIndex: maximumIndex,
            imageMediaTypes: imageMediaTypes
        )
    }

    /// glTF's `NORMAL` is a unit vector. A longer one is refused rather than normalized,
    /// so an attribute holds what it was given.
    private func validateNormalsAreUnit() throws {
        for normal in normals ?? [] {
            let length = simd_length(normal)
            guard abs(length - 1) <= 1e-3 else {
                throw VRMError._invalidArgument(
                    "normals have to be unit vectors, and \(normal) is \(length) long"
                )
            }
        }
    }

    /// glTF has every accessor of a primitive hold as many elements as its positions.
    private func validateAttribute<Vector: SIMD>(_ values: [Vector]?,
                                                 named attribute: String) throws
    where Vector.Scalar == Float {
        guard let values else { return }
        guard values.count == positions.count else {
            throw VRMError._invalidArgument(
                "the mesh has \(positions.count) positions and \(values.count) \(attribute), which have to match"
            )
        }
        for value in values {
            for component in 0..<Vector.scalarCount where !value[component].isFinite {
                throw VRMError._invalidArgument("\(attribute) cannot contain infinity or NaN")
            }
        }
    }
}

extension GLTFSimpleMaterial {
    /// The media type of each image the material shows, nil where it shows none.
    struct ImageMediaTypes {
        var baseColor: String?
        var emissive: String?

        var isEmpty: Bool { baseColor == nil && emissive == nil }
    }

    /// Validates the values glTF writes into JSON and returns the image types.
    func validate() throws -> ImageMediaTypes {
        for component in 0..<SIMD4<Float>.scalarCount {
            let value = baseColorFactor[component]
            guard value.isFinite, (0...1).contains(value) else {
                throw VRMError._invalidArgument(
                    "baseColorFactor components must be finite and in 0...1, got \(value)"
                )
            }
        }
        if case .mask(let cutoff) = alphaMode {
            guard cutoff.isFinite, cutoff >= 0 else {
                throw VRMError._invalidArgument("an alpha cutoff must be a finite, nonnegative number")
            }
        }
        for component in 0..<SIMD3<Float>.scalarCount {
            let value = emissiveFactor[component]
            guard value.isFinite, (0...1).contains(value) else {
                throw VRMError._invalidArgument(
                    "emissiveFactor components must be finite and in 0...1, got \(value)"
                )
            }
        }
        return ImageMediaTypes(baseColor: try Self.mediaType(of: baseColorImage, named: "a base color image"),
                               emissive: try Self.mediaType(of: emissiveImage, named: "an emissive image"))
    }

    private static func mediaType(of image: Data?, named name: String) throws -> String? {
        guard let image else { return nil }
        return try image.imageMediaType
            ??? ._notSupported("\(name) has to be a PNG or a JPEG, which these bytes are neither of")
    }
}
