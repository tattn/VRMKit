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
                public let shadeColorFactor: [Either<Int, Double>]?
                public let shadeMultiplyTexture: MaterialsMToonTextureInfo?
                public let shadingShiftFactor: Double?
                public let shadingShiftTexture: MaterialsMToonShadingShiftTextureInfo?
                public let shadingToonyFactor: Double?
                public let giEqualizationFactor: Double?
                public let matcapFactor: [Either<Int, Double>]?
                public let matcapTexture: MaterialsMToonTextureInfo?
                public let parametricRimColorFactor: [Either<Int, Double>]?
                public let rimMultiplyTexture: MaterialsMToonTextureInfo?
                public let rimLightingMixFactor: Double?
                public let parametricRimFresnelPowerFactor: Double?
                public let parametricRimLiftFactor: Double?
                public let outlineWidthMode: MaterialsMToonOutlineWidthMode?
                public let outlineWidthFactor: Double?
                public let outlineWidthMultiplyTexture: MaterialsMToonTextureInfo?
                public let outlineColorFactor: [Either<Int, Double>]?
                public let outlineLightingMixFactor: Double?
                public let uvAnimationMaskTexture: MaterialsMToonTextureInfo?
                public let uvAnimationScrollXSpeedFactor: Double?
                public let uvAnimationScrollYSpeedFactor: Double?
                public let uvAnimationRotationSpeedFactor: Double?
                
                public struct MaterialsMToonTextureInfo: Codable {
                    public let index: Double
                    public let texCoord: Double?
                    
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        index = try decodeDouble(key: .index, container: container)
                        texCoord = try? decodeDouble(key: .texCoord, container: container)
                    }
                }
                
                public struct MaterialsMToonShadingShiftTextureInfo: Codable {
                    public let index: Double
                    public let texCoord: Double?
                    public let scale: Double?
                    
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        index = try decodeDouble(key: .index, container: container)
                        texCoord = try? decodeDouble(key: .texCoord, container: container)
                        scale = try? decodeDouble(key: .scale, container: container)
                    }
                }
                
                public enum MaterialsMToonOutlineWidthMode: String, Codable {
                    case none
                    case worldCoordinates
                    case screenCoordinates
                }
                
                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    specVersion = try container.decode(String.self, forKey: .specVersion)
                    transparentWithZWrite = try container.decodeIfPresent(Bool.self, forKey: .transparentWithZWrite)
                    renderQueueOffsetNumber = try container.decodeIfPresent(Int.self, forKey: .renderQueueOffsetNumber)
                    shadeColorFactor = try container.decodeIfPresent([Either<Int, Double>].self, forKey: .shadeColorFactor)
                    shadeMultiplyTexture = try container.decodeIfPresent(MaterialsMToonTextureInfo.self, forKey: .shadeMultiplyTexture)
                    shadingShiftFactor = try? decodeDouble(key: .shadingShiftFactor, container: container)
                    shadingShiftTexture = try container.decodeIfPresent(MaterialsMToonShadingShiftTextureInfo.self, forKey: .shadingShiftTexture)
                    shadingToonyFactor = try? decodeDouble(key: .shadingToonyFactor, container: container)
                    giEqualizationFactor = try? decodeDouble(key: .giEqualizationFactor, container: container)
                    matcapFactor = try container.decodeIfPresent([Either<Int, Double>].self, forKey: .matcapFactor)
                    matcapTexture = try container.decodeIfPresent(MaterialsMToonTextureInfo.self, forKey: .matcapTexture)
                    parametricRimColorFactor = try container.decodeIfPresent([Either<Int, Double>].self, forKey: .parametricRimColorFactor)
                    rimMultiplyTexture = try container.decodeIfPresent(MaterialsMToonTextureInfo.self, forKey: .rimMultiplyTexture)
                    rimLightingMixFactor = try? decodeDouble(key: .rimLightingMixFactor, container: container)
                    parametricRimFresnelPowerFactor = try? decodeDouble(key: .parametricRimFresnelPowerFactor, container: container)
                    parametricRimLiftFactor = try? decodeDouble(key: .parametricRimLiftFactor, container: container)
                    outlineWidthMode = try container.decodeIfPresent(MaterialsMToonOutlineWidthMode.self, forKey: .outlineWidthMode)
                    outlineWidthFactor = try? decodeDouble(key: .outlineWidthFactor, container: container)
                    outlineWidthMultiplyTexture = try container.decodeIfPresent(MaterialsMToonTextureInfo.self, forKey: .outlineWidthMultiplyTexture)
                    outlineColorFactor = try container.decodeIfPresent([Either<Int, Double>].self, forKey: .outlineColorFactor)
                    outlineLightingMixFactor = try? decodeDouble(key: .outlineLightingMixFactor, container: container)
                    uvAnimationMaskTexture = try container.decodeIfPresent(MaterialsMToonTextureInfo.self, forKey: .uvAnimationMaskTexture)
                    uvAnimationScrollXSpeedFactor = try? decodeDouble(key: .uvAnimationScrollXSpeedFactor, container: container)
                    uvAnimationScrollYSpeedFactor = try? decodeDouble(key: .uvAnimationScrollYSpeedFactor, container: container)
                    uvAnimationRotationSpeedFactor = try? decodeDouble(key: .uvAnimationRotationSpeedFactor, container: container)
                }
            }
        }
    }
}
