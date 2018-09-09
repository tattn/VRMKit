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
        public let extensions: CodableAny?
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
    }
}
