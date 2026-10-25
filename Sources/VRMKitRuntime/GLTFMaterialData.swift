import Foundation
import VRMKit

/// One glTF material with what reading it decides: how it shades, how it cuts out or
/// blends, the queue it draws in, and the UV set and transform its textures read through.
/// The factors and textures themselves are the glTF material's, or the MToon descriptor's.
public struct GLTFMaterialData: Sendable {
    public enum Shading: Sendable {
        /// glTF's metallic-roughness model.
        case physicallyBased
        /// Flat color: `KHR_materials_unlit`, a VRM 0.x unlit shader, or MToon of a spec
        /// version this package does not read.
        case unlit
        case mtoon(MToonMaterialDescriptor)
    }

    public let index: Int
    public let material: GLTF.Material
    public let shading: Shading
    /// As authored, VRM 0.x shader metadata taking priority over the glTF alpha mode as
    /// UniVRM reads it.
    public let alphaMode: GLTF.Material.AlphaMode
    /// How the material draws: ``alphaMode``, except that a MASK material whose base color
    /// alpha reaches the cutoff at every texel its triangles sample draws OPAQUE, since a draw
    /// that may discard forgoes the GPU's rejection of hidden fragments. Telling needs the
    /// decoded image, so a read that decodes none keeps ``alphaMode``.
    public let resolvedAlphaMode: GLTF.Material.AlphaMode
    /// The queue a blended material draws in: the one VRM 0.x recorded, or the mode's base
    /// queue moved by MToon's offset. Nil unless blended.
    public let renderQueue: Int?
    /// The UV set the meshes drawing the material carry: the first UV-accessed texture's.
    /// A mesh carries one UV set, so a texture naming another reads through this one.
    public let texCoord: Int
    /// The UV transform the textures read through: the first UV-accessed texture's.
    public let uvTransform: GLTFUVTransform

    /// The textures the material samples, each with how it is read.
    public var sampledTextures: [(texture: GLTFSampledTexture, usage: GLTFImageSource.Usage)] {
        switch shading {
        case .mtoon(let mtoon):
            return [(mtoon.baseColorTexture, .color),
                    (mtoon.shadeMultiplyTexture, .color),
                    (mtoon.shadingShiftTexture, .raw),
                    (mtoon.normalTexture, .normal),
                    (mtoon.matcapTexture, .color),
                    (mtoon.emissiveTexture, .color),
                    (mtoon.rimMultiplyTexture, .color),
                    (mtoon.outlineWidthMultiplyTexture, .raw),
                    (mtoon.uvAnimationMaskTexture, .raw)].compactMap { texture, usage in texture.map { ($0, usage) } }
        case .unlit:
            return [material.pbrMetallicRoughness?.baseColorTexture.map { (GLTFSampledTexture($0), .color) }]
                .compactMap { $0 }
        case .physicallyBased:
            let pbr = material.pbrMetallicRoughness
            return [pbr?.baseColorTexture.map { (GLTFSampledTexture($0), .color) },
                    pbr?.metallicRoughnessTexture.map { (GLTFSampledTexture($0), .raw) },
                    material.normalTexture.map { (GLTFSampledTexture($0), .normal) },
                    material.occlusionTexture.map { (GLTFSampledTexture($0), .raw) },
                    material.emissiveTexture.map { (GLTFSampledTexture($0), .color) }].compactMap { $0 }
        }
    }

    /// `drawsCutoutOpaque` says the MASK material discards nothing (``resolvedAlphaMode``).
    package init(index: Int, material: GLTF.Material, materialProperty: VRM0.MaterialProperty?,
                 drawsCutoutOpaque: Bool = false) {
        self.index = index
        self.material = material
        let resolution = MToonMaterialDescriptor.resolve(material: material, materialProperty: materialProperty)
        let isUnlit = materialProperty?.shader.lowercased().contains("unlit") == true
            || material.extensions?.materialsUnlit != nil
        if let descriptor = resolution.descriptor {
            shading = .mtoon(descriptor)
        } else if resolution.isMToon || isUnlit {
            // Unreadable MToon is still MToon, so it takes the same flat approximation.
            shading = .unlit
        } else {
            shading = .physicallyBased
        }
        alphaMode = GLTF.Material.AlphaMode(vrm0: materialProperty, fallback: material.alphaMode)
        resolvedAlphaMode = alphaMode == .MASK && drawsCutoutOpaque ? .OPAQUE : alphaMode
        renderQueue = Self.renderQueue(alphaMode: alphaMode,
                                       materialProperty: materialProperty,
                                       transparentWithZWrite: resolution.descriptor?.transparentWithZWrite ?? false,
                                       offset: resolution.descriptor?.renderQueueOffsetNumber ?? 0)
        let textures = GLTFAssetReader.sampledTextures(of: material)
        texCoord = textures.first?.texCoord ?? 0
        let uvAccessed = resolution.descriptor?.uvAccessedTextures ?? textures
        uvTransform = uvAccessed.first?.transform ?? GLTFUVTransform()
    }

    /// The queue a material drawn as `alphaMode` draws in: the one VRM 0.x recorded, or the
    /// mode's base queue moved by MToon's `offset`, where a depth-writing blend draws ahead
    /// of the rest. Nil unless blended.
    package static func renderQueue(alphaMode: GLTF.Material.AlphaMode,
                                    materialProperty: VRM0.MaterialProperty?,
                                    transparentWithZWrite: Bool,
                                    offset: Int) -> Int? {
        guard alphaMode == .BLEND else { return nil }
        if let materialProperty { return materialProperty.renderQueue }
        return alphaMode.vrm0RenderQueue(transparentWithZWrite: transparentWithZWrite) + offset
    }
}

/// One glTF image as the document stores it. Decoding it and putting it on the GPU is
/// the renderer's.
public struct GLTFImageSource: Sendable {
    /// How a material reads an image, which decides how its texels are decoded.
    public enum Usage: Hashable, Sendable {
        /// sRGB color.
        case color
        /// A tangent-space normal map.
        case normal
        /// Linear data, such as metalness, occlusion or a mask.
        case raw
    }

    public let index: Int
    /// How the materials read the image. Empty for one no material samples.
    public let usages: Set<Usage>
    private let document: GLTFDocument

    package init(index: Int, document: GLTFDocument, usages: Set<Usage>) {
        self.index = index
        self.document = document
        self.usages = usages
    }

    /// The MIME type the document gives, or else the one the bytes name themselves.
    public var mimeType: String? {
        document.gltf.images[safe: index]?.mimeType ?? (try? data())?.imageMediaType
    }

    /// The bytes the document stores the image as: a PNG, a JPEG or whatever its MIME type names.
    public func data() throws -> Data {
        try document.imageData(at: index)
    }
}
