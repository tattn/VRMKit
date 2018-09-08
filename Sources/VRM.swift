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

    public init(data: Data) throws {
        gltf = try BinaryGLTF(data: data)

        let rawExtensions = try gltf.jsonData.extensions ??? .keyNotFound("extensions")
        let extensions = try rawExtensions.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")
        let vrm = try extensions["VRM"] ??? .keyNotFound("VRM")

        let decoder = DictionaryDecoder()
        meta = try decoder.decode(Meta.self, from: try vrm["meta"] ??? .keyNotFound("meta"))
        version = try vrm["version"] as? String ??? .keyNotFound("version")
        materialProperties = try decoder.decode([MaterialProperty].self, from: try vrm["materialProperties"] ??? .keyNotFound("materialProperties"))
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
}
