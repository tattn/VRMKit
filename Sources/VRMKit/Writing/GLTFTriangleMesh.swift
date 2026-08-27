import Foundation
import simd

/// The vertex data of one indexed triangle mesh, as
/// ``GLTFEditableDocument/addMesh(_:under:name:transform:materials:)`` writes it.
///
/// Anything richer is authored in a DCC tool and brought in with
/// ``GLTFEditableDocument/append(_:under:name:transform:materials:)``.
public struct GLTFTriangleMesh: Equatable, Sendable {
    public var positions: [SIMD3<Float>]

    /// One unit vector per position, or none to leave the mesh flat-shaded.
    public var normals: [SIMD3<Float>]?

    /// One per position, in glTF's convention: `v` grows downwards from the top
    /// edge of the image. A material showing an image needs them.
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

/// What a texture coordinate outside `[0, 1]` samples, and how the image is
/// filtered. The defaults are glTF's own, so a sampler left alone is not written
/// at all.
public struct GLTFTextureSampler: Hashable, Sendable {
    public var wrapS: GLTF.Sampler.Wrap

    public var wrapT: GLTF.Sampler.Wrap

    /// Nil leaves the choice to the renderer, as glTF does for a sampler naming no
    /// filter.
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

/// The part of a glTF material an authored mesh needs: a base color, and how its
/// alpha is read. Toon shading is `addMesh`'s `materials` parameter instead.
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

    /// A PNG or a JPEG, the two formats a glTF image may hold. Anything else is
    /// refused rather than transcoded.
    public var baseColorImage: Data?

    /// A plate showing one picture wants `CLAMP_TO_EDGE` rather than the tiling
    /// glTF defaults to.
    public var baseColorSampler: GLTFTextureSampler

    /// Shades the surface with its base color alone, through `KHR_materials_unlit`.
    public var isUnlit: Bool

    public var alphaMode: AlphaMode

    /// Draws the back faces too, which a plate seen from either side needs.
    public var isDoubleSided: Bool

    public init(name: String? = nil,
                baseColorFactor: SIMD4<Float> = SIMD4(1, 1, 1, 1),
                baseColorImage: Data? = nil,
                baseColorSampler: GLTFTextureSampler = .init(),
                isUnlit: Bool = false,
                alphaMode: AlphaMode = .opaque,
                isDoubleSided: Bool = false) {
        self.name = name
        self.baseColorFactor = baseColorFactor
        self.baseColorImage = baseColorImage
        self.baseColorSampler = baseColorSampler
        self.isUnlit = isUnlit
        self.alphaMode = alphaMode
        self.isDoubleSided = isDoubleSided
    }
}

struct ValidatedTriangleMesh {
    let positionBounds: (min: [Float], max: [Float])
    let maximumIndex: UInt32
    let imageMediaType: String?
}

extension GLTFTriangleMesh {
    /// Checked before any of the mesh is written, so that one glTF cannot describe
    /// leaves the document alone rather than half written into it.
    func validate() throws -> ValidatedTriangleMesh {
        guard !positions.isEmpty else {
            throw VRMError._dataInconsistent("a mesh needs at least one vertex, and this one has no positions")
        }
        var minimum = positions[0]
        var maximum = positions[0]
        for position in positions {
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                throw VRMError._dataInconsistent("positions cannot contain infinity or NaN")
            }
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }
        try validateAttribute(normals, named: "normals")
        try validateNormalsAreUnit()
        try validateAttribute(textureCoordinates, named: "textureCoordinates")

        guard !indices.isEmpty else {
            throw VRMError._dataInconsistent("a mesh needs at least one triangle, and this one has no indices")
        }
        guard indices.count % 3 == 0 else {
            throw VRMError._dataInconsistent(
                "\(indices.count) indices are not a whole number of triangles"
            )
        }
        let maximumIndex = indices.max()!
        if Int(maximumIndex) >= positions.count {
            throw VRMError._dataInconsistent(
                "index \(maximumIndex) is out of range for the \(positions.count) vertices of the mesh"
            )
        }

        let imageMediaType: String?
        if let material {
            imageMediaType = try material.validate()
        } else {
            imageMediaType = nil
        }
        // A texture naming no `texCoord` is read at `TEXCOORD_0`.
        guard imageMediaType == nil || textureCoordinates != nil else {
            throw VRMError._dataInconsistent(
                "a material with a base color image needs the texture coordinates to read it at"
            )
        }
        return ValidatedTriangleMesh(
            positionBounds: ([minimum.x, minimum.y, minimum.z], [maximum.x, maximum.y, maximum.z]),
            maximumIndex: maximumIndex,
            imageMediaType: imageMediaType
        )
    }

    /// glTF's `NORMAL` is the unit vector a renderer shades with. A longer one is
    /// refused rather than normalized, so an attribute holds what it was given.
    private func validateNormalsAreUnit() throws {
        for normal in normals ?? [] {
            let length = simd_length(normal)
            guard abs(length - 1) <= 1e-3 else {
                throw VRMError._dataInconsistent(
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
            throw VRMError._dataInconsistent(
                "the mesh has \(positions.count) positions and \(values.count) \(attribute), which have to match"
            )
        }
        for value in values {
            for component in 0..<Vector.scalarCount where !value[component].isFinite {
                throw VRMError._dataInconsistent("\(attribute) cannot contain infinity or NaN")
            }
        }
    }
}

extension GLTFSimpleMaterial {
    /// Validates the values glTF writes into JSON and returns the image type.
    func validate() throws -> String? {
        for component in 0..<SIMD4<Float>.scalarCount {
            let value = baseColorFactor[component]
            guard value.isFinite, (0...1).contains(value) else {
                throw VRMError._dataInconsistent(
                    "baseColorFactor components must be finite and in 0...1, got \(value)"
                )
            }
        }
        if case .mask(let cutoff) = alphaMode {
            guard cutoff.isFinite, cutoff >= 0 else {
                throw VRMError._dataInconsistent("an alpha cutoff must be a finite, nonnegative number")
            }
        }
        guard let baseColorImage else { return nil }
        return try baseColorImage.imageMediaType
            ??? ._notSupported("a base color image has to be a PNG or a JPEG, which these bytes are neither of")
    }
}
