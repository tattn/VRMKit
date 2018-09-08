//
//  VRM.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

public struct VRM {
    public let gltf: BinaryGLTF
    public let meta: Meta
    public let version: String
    public let materialProperties: [MaterialProperty]
    public let humanoid: Humanoid
    public let blendShapeMaster: BlendShapeMaster

    public init(data: Data) throws {
        gltf = try BinaryGLTF(data: data)

        let rawExtensions = try gltf.jsonData.extensions ??? .keyNotFound("extensions")
        let extensions = try rawExtensions.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")
        let vrm = try extensions["VRM"] ??? .keyNotFound("VRM")

        let decoder = DictionaryDecoder()
        meta = try decoder.decode(Meta.self, from: try vrm["meta"] ??? .keyNotFound("meta"))
        version = try vrm["version"] as? String ??? .keyNotFound("version")
        materialProperties = try decoder.decode([MaterialProperty].self, from: try vrm["materialProperties"] ??? .keyNotFound("materialProperties"))
        humanoid = try decoder.decode(Humanoid.self, from: try vrm["humanoid"] ??? .keyNotFound("humanoid"))
        blendShapeMaster = try decoder.decode(BlendShapeMaster.self, from: try vrm["blendShapeMaster"] ??? .keyNotFound("blendShapeMaster"))
    }
}

extension VRM {
    public struct Meta: Codable {
        public let title: String
        public let author: String
        public let contactInformation: String
        public let reference: String
        public let texture: Int
        public let version: String

        public let allowedUserName: String
        public let violentUssageName: String
        public let sexualUssageName: String
        public let commercialUssageName: String
        public let otherPermissionUrl: String

        public let licenseName: String
        public let otherLicenseUrl: String
    }

    public struct MaterialProperty: Codable {
        public let name: String
        public let shader: String
        public let renderQueue: Int
        public let floatProperties: GLTF.Extensions
        public let keywordMap: [String: Bool]
        public let tagMap: [String: String]
        public let textureProperties: [String: Int]
        public let vectorProperties: GLTF.Extensions
    }

    public struct Humanoid: Codable {
        public let armStretch: Double
        public let feetSpacing: Double
        public let hasTranslationDoF: Bool
        public let legStretch: Double
        public let lowerArmTwist: Double
        public let lowerLegTwist: Double
        public let upperArmTwist: Double
        public let upperLegTwist: Double
        public let humanBones: [HumanBone]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            armStretch = try decodeDouble(key: .armStretch, container: container)
            feetSpacing = try decodeDouble(key: .feetSpacing, container: container)
            hasTranslationDoF = try container.decode(Bool.self, forKey: .hasTranslationDoF)
            legStretch = try decodeDouble(key: .legStretch, container: container)
            lowerArmTwist = try decodeDouble(key: .lowerArmTwist, container: container)
            lowerLegTwist = try decodeDouble(key: .lowerLegTwist, container: container)
            upperArmTwist = try decodeDouble(key: .upperArmTwist, container: container)
            upperLegTwist = try decodeDouble(key: .upperLegTwist, container: container)
            humanBones = try container.decode([HumanBone].self, forKey: .humanBones)
        }

        public struct HumanBone: Codable {
            public let bone: String
            public let node: Int
            public let useDefaultValues: Bool
        }
    }

    public struct BlendShapeMaster: Codable {
        public let blendShapeGroups: [BlendShapeGroup]
        public struct BlendShapeGroup: Codable {
            public let binds: [Bind]
            public let materialValues: [GLTF.Extensions]
            public let name: String
            public let presetName: String
            public struct Bind: Codable {
                public let index: Int
                public let mesh: Int
                public let weight: Double

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    index = try container.decode(Int.self, forKey: .index)
                    mesh = try container.decode(Int.self, forKey: .mesh)
                    weight = try decodeDouble(key: .weight, container: container)
                }
            }
        }
    }
}

private func decodeDouble<T: CodingKey>(key: T, container: KeyedDecodingContainer<T>) throws -> Double {
    return try (try? container.decode(Double.self, forKey: key)) ?? Double(try container.decode(Int.self, forKey: key))
}
