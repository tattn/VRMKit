import Foundation
import simd

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#material

extension GLTF {
    public struct Material: Codable, Sendable {
        public let name: String?
        public let extensions: MaterialExtensions?
        public let extras: JSONValue?
        public let pbrMetallicRoughness: PbrMetallicRoughness?
        public let normalTexture: NormalTextureInfo?
        public let occlusionTexture: OcclusionTextureInfo?
        public let emissiveTexture: TextureInfo?
        let _emissiveFactor: SIMD3<Float>?
        public var emissiveFactor: SIMD3<Float> { _emissiveFactor ?? .zero }
        let _alphaMode: AlphaMode?
        public var alphaMode: AlphaMode { return _alphaMode ?? .OPAQUE }
        let _alphaCutoff: Float?
        public var alphaCutoff: Float { return _alphaCutoff ?? 0.5 }
        let _doubleSided: Bool?
        public var doubleSided: Bool { return _doubleSided ?? false }
        private enum CodingKeys: String, CodingKey {
            case name
            case extensions
            case extras
            case pbrMetallicRoughness
            case normalTexture
            case occlusionTexture
            case emissiveTexture
            case _emissiveFactor = "emissiveFactor"
            case _alphaMode = "alphaMode"
            case _alphaCutoff = "alphaCutoff"
            case _doubleSided = "doubleSided"
        }

        public struct PbrMetallicRoughness: Codable, Sendable {
            let _baseColorFactor: SIMD4<Float>?
            public var baseColorFactor: SIMD4<Float> { _baseColorFactor ?? SIMD4<Float>(repeating: 1) }
            public let baseColorTexture: TextureInfo?
            let _metallicFactor: Float?
            public var metallicFactor: Float { return _metallicFactor ?? 1 }
            let _roughnessFactor: Float?
            public var roughnessFactor: Float { return _roughnessFactor ?? 1 }
            public let metallicRoughnessTexture: TextureInfo?
            public let extensions: JSONValue?
            public let extras: JSONValue?
            private enum CodingKeys: String, CodingKey {
                case _baseColorFactor = "baseColorFactor"
                case baseColorTexture
                case _metallicFactor = "metallicFactor"
                case _roughnessFactor = "roughnessFactor"
                case metallicRoughnessTexture
                case extensions
                case extras
            }
        }

        public struct NormalTextureInfo: Codable, Sendable {
            public let index: Int
            let _texCoord: Int?
            public var texCoord: Int { return _texCoord ?? 0 }
            let _scale: Float?
            public var scale: Float { return _scale ?? 1 }
            public let extensions: JSONValue?
            public let extras: JSONValue?
            private enum CodingKeys: String, CodingKey {
                case index
                case _texCoord = "texCoord"
                case _scale = "scale"
                case extensions
                case extras
            }
        }

        public struct OcclusionTextureInfo: Codable, Sendable {
            public let index: Int
            let _texCoord: Int?
            public var texCoord: Int { return _texCoord ?? 0 }
            let _strength: Float?
            public var strength: Float { return _strength ?? 1 }
            public let extensions: JSONValue?
            public let extras: JSONValue?
            private enum CodingKeys: String, CodingKey {
                case index
                case _texCoord = "texCoord"
                case _strength = "strength"
                case extensions
                case extras
            }
        }

        public enum AlphaMode: String, Codable, Sendable {
            case OPAQUE
            case MASK
            case BLEND
        }
        
        public struct MaterialExtensions: Codable, Sendable {
            /// Every extension on the material as the document wrote it, the modeled
            /// ones included, so an unmodeled one is still readable.
            public let raw: [String: JSONValue]
            public let materialsMToon: MaterialsMToon?
            public let materialsUnlit: MaterialsUnlit?

            /// The extension named `name`, as it was written.
            public subscript(name: String) -> JSONValue? { raw[name] }

            public init(from decoder: Decoder) throws {
                raw = try JSONValue(from: decoder).objectValue ?? [:]
                materialsMToon = try raw[GLTFExtension.materialsMToon.rawValue]?.decode(MaterialsMToon.self)
                materialsUnlit = raw[GLTFExtension.materialsUnlit.rawValue].map { _ in MaterialsUnlit() }
            }

            public func encode(to encoder: Encoder) throws {
                try JSONValue.object(raw).encode(to: encoder)
            }

            /// The `KHR_materials_unlit` marker, an empty object in glTF.
            public struct MaterialsUnlit: Codable, Sendable {}

            public struct MaterialsMToon: Codable, Sendable {
                /// Nil where the document leaves it out, treated as an unsupported
                /// version rather than failing the load.
                public let specVersion: String?
                public let transparentWithZWrite: Bool?
                public let renderQueueOffsetNumber: Int?
                public let shadeColorFactor: [Double]?
                public let shadeMultiplyTexture: MaterialsMToonTextureInfo?
                public let shadingShiftFactor: Double?
                public let shadingShiftTexture: MaterialsMToonShadingShiftTexture?
                public let shadingToonyFactor: Double?
                public let giEqualizationFactor: Double?
                public let matcapFactor: [Double]?
                public let matcapTexture: MaterialsMToonTextureInfo?
                public let parametricRimColorFactor: [Double]?
                public let rimMultiplyTexture: MaterialsMToonTextureInfo?
                public let rimLightingMixFactor: Double?
                public let parametricRimFresnelPowerFactor: Double?
                public let parametricRimLiftFactor: Double?
                public let outlineWidthMode: MaterialsMToonOutlineWidthMode?
                public let outlineWidthFactor: Double?
                public let outlineWidthMultiplyTexture: MaterialsMToonTextureInfo?
                public let outlineColorFactor: [Double]?
                public let outlineLightingMixFactor: Double?
                public let uvAnimationMaskTexture: MaterialsMToonTextureInfo?
                public let uvAnimationScrollXSpeedFactor: Double?
                public let uvAnimationScrollYSpeedFactor: Double?
                public let uvAnimationRotationSpeedFactor: Double?
                public let extensions: JSONValue?
                public let extras: JSONValue?
                
                public struct MaterialsMToonTextureInfo: Codable, Sendable {
                    public let index: Int
                    public let texCoord: Int?
                    public let extensions: JSONValue?
                    public let extras: JSONValue?
                }
                
                public struct MaterialsMToonShadingShiftTexture: Codable, Sendable {
                    public let index: Int
                    public let texCoord: Int?
                    public let scale: Double?
                    public let extensions: JSONValue?
                    public let extras: JSONValue?
                }
                
                /// The one outline mode every layer of this package speaks, so a decoded
                /// material and a written one cannot drift.
                public typealias MaterialsMToonOutlineWidthMode = MToonOutlineWidthMode
            }
        }
    }
}
