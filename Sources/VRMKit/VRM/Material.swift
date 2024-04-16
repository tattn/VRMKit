//
//  Material.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

// https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#material

extension GLTF {
    public struct Material: Codable {
        public let name: String?
        public let extensions: MaterialExtensions?
        public let extras: CodableAny?
        public let pbrMetallicRoughness: PbrMetallicRoughness?
        public let normalTexture: NormalTextureInfo?
        public let occlusionTexture: OcclusionTextureInfo?
        public let emissiveTexture: TextureInfo?
        let _emissiveFactor: Color3?
        public var emissiveFactor: Color3 { return _emissiveFactor ?? .black }
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

        public struct PbrMetallicRoughness: Codable {
            let _baseColorFactor: Color4?
            public var baseColorFactor: Color4 { return _baseColorFactor ?? .init(r: 0, g: 0, b: 0, a: 0) }
            public let baseColorTexture: TextureInfo?
            let _metallicFactor: Float?
            public var metallicFactor: Float { return _metallicFactor ?? 1 }
            let _roughnessFactor: Float?
            public var roughnessFactor: Float { return _roughnessFactor ?? 1 }
            public let metallicRoughnessTexture: TextureInfo?
            public let extensions: CodableAny?
            public let extras: CodableAny?
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

        public struct NormalTextureInfo: Codable {
            public let index: Int
            let _texCoord: Int?
            public var texCoord: Int { return _texCoord ?? 0 }
            let _scale: Float?
            public var scale: Float { return _scale ?? 1 }
            public let extensions: CodableAny?
            public let extras: CodableAny?
            private enum CodingKeys: String, CodingKey {
                case index
                case _texCoord = "texCoord"
                case _scale = "scale"
                case extensions
                case extras
            }
        }

        public struct OcclusionTextureInfo: Codable {
            public let index: Int
            let _texCoord: Int?
            public var texCoord: Int { return _texCoord ?? 0 }
            let _strength: Float?
            public var strength: Float { return _strength ?? 1 }
            public let extensions: CodableAny?
            public let extras: CodableAny?
            private enum CodingKeys: String, CodingKey {
                case index
                case _texCoord = "texCoord"
                case _strength = "strength"
                case extensions
                case extras
            }
        }

        public enum AlphaMode: String, Codable {
            case OPAQUE
            case MASK
            case BLEND
        }
        
        public struct MaterialExtensions: Codable {
            public let materialsMToon: MaterialsMToon?

            private enum CodingKeys: String, CodingKey {
                case materialsMToon = "VRMC_materials_mtoon"
            }

            public struct MaterialsMToon: Codable {
                public let specVersion: String
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
                public let extensions: CodableAny?
                public let extras: CodableAny?
                
                public struct MaterialsMToonTextureInfo: Codable {
                    public let index: Int
                    public let texCoord: Int?
                    public let extensions: CodableAny?
                    public let extras: CodableAny?
                    
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        index = try container.decode(Int.self, forKey: .index)
                        texCoord = try container.decodeIfPresent(Int.self, forKey: .texCoord)
                        extensions = try container.decodeIfPresent(CodableAny.self, forKey: .extensions)
                        extras = try container.decodeIfPresent(CodableAny.self, forKey: .extras)
                    }
                }
                
                public struct MaterialsMToonShadingShiftTexture: Codable {
                    public let index: Int
                    public let texCoord: Int?
                    public let scale: Double?
                    public let extensions: CodableAny?
                    public let extras: CodableAny?
                }
                
                public enum MaterialsMToonOutlineWidthMode: String, Codable {
                    case none
                    case worldCoordinates
                    case screenCoordinates
                }
            }
        }
    }
}
