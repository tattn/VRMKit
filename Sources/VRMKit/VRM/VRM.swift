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
    public let version: String?
    public let materialProperties: [MaterialProperty]
    public let humanoid: Humanoid
    public let blendShapeMaster: BlendShapeMaster
    public let firstPerson: FirstPerson
    public let secondaryAnimation: SecondaryAnimation

    public let materialPropertyNameMap: [String: MaterialProperty]

    public init(data: Data) throws {
        gltf = try BinaryGLTF(data: data)

        let rawExtensions = try gltf.jsonData.extensions ??? .keyNotFound("extensions")
        let extensions = try rawExtensions.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")
        let vrm = try extensions["VRM"] ??? .keyNotFound("VRM")

        let decoder = DictionaryDecoder()
        meta = try decoder.decode(Meta.self, from: try vrm["meta"] ??? .keyNotFound("meta"))
        version = vrm["version"] as? String
        materialProperties = try decoder.decode([MaterialProperty].self, from: try vrm["materialProperties"] ??? .keyNotFound("materialProperties"))
        humanoid = try decoder.decode(Humanoid.self, from: try vrm["humanoid"] ??? .keyNotFound("humanoid"))
        blendShapeMaster = try decoder.decode(BlendShapeMaster.self, from: try vrm["blendShapeMaster"] ??? .keyNotFound("blendShapeMaster"))
        firstPerson = try decoder.decode(FirstPerson.self, from: try vrm["firstPerson"] ??? .keyNotFound("firstPerson"))
        secondaryAnimation = try decoder.decode(SecondaryAnimation.self, from: try vrm["secondaryAnimation"] ??? .keyNotFound("secondaryAnimation"))

        materialPropertyNameMap = materialProperties.reduce(into: [:]) { $0[$1.name] = $1 }
    }
}

public extension VRM {
    struct Meta: Codable {
        public let title: String?
        public let author: String?
        public let contactInformation: String?
        public let reference: String?
        public let texture: Int?
        public let version: String?

        public let allowedUserName: String?
        public let violentUssageName: String?
        public let sexualUssageName: String?
        public let commercialUssageName: String?
        public let otherPermissionUrl: String?

        public let licenseName: String?
        public let otherLicenseUrl: String?
    }

    struct MaterialProperty: Codable {
        public let name: String
        public let shader: String
        public let renderQueue: Int
        public let floatProperties: CodableAny
        public let keywordMap: [String: Bool]
        public let tagMap: [String: String]
        public let textureProperties: [String: Int]
        public let vectorProperties: CodableAny
    }

    struct Humanoid: Codable {
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

    struct BlendShapeMaster: Codable {
        public let blendShapeGroups: [BlendShapeGroup]
        public struct BlendShapeGroup: Codable {
            public let binds: [Bind]?
            public let materialValues: [MaterialValueBind]?
            public let name: String
            public let presetName: String
            let _isBinary: Bool?
            public var isBinary: Bool { return _isBinary ?? false }
            private enum CodingKeys: String, CodingKey {
                case binds
                case materialValues
                case name
                case presetName
                case _isBinary = "isBinary"
            }
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
            public struct MaterialValueBind: Codable {
                public let materialName: String
                public let propertyName: String
                public let targetValue: [Double]
            }
        }
    }

    struct FirstPerson: Codable {
        public let firstPersonBone: Int
        public let firstPersonBoneOffset: Vector3
        public let meshAnnotations: [MeshAnnotation]
        public let lookAtTypeName: LookAtType
        
        public struct MeshAnnotation: Codable {
            public let firstPersonFlag: String
            public let mesh: Int
        }
        public enum LookAtType: String, Codable {
            case none = "None"
            case bone = "Bone"
            case blendShape = "BlendShape"
        }
    }

    struct SecondaryAnimation: Codable {
        public let boneGroups: [BoneGroup]
        public let colliderGroups: [ColliderGroup]
        public struct BoneGroup: Codable {
            public let bones: [Int]
            public let center: Int
            public let colliderGroups: [Int]
            public let comment: String?
            public let dragForce: Double
            public let gravityDir: Vector3
            public let gravityPower: Double
            public let hitRadius: Double
            public let stiffiness: Double

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                bones = try container.decode([Int].self, forKey: .bones)
                center = try container.decode(Int.self, forKey: .center)
                colliderGroups = try container.decode([Int].self, forKey: .colliderGroups)
                comment = try? container.decode(String.self, forKey: .comment)
                dragForce = try decodeDouble(key: .dragForce, container: container)
                gravityDir = try container.decode(Vector3.self, forKey: .gravityDir)
                gravityPower = try decodeDouble(key: .gravityPower, container: container)
                hitRadius = try decodeDouble(key: .hitRadius, container: container)
                stiffiness = try decodeDouble(key: .stiffiness, container: container)
            }
        }
        
        public struct ColliderGroup: Codable {
            public let node: Int
            public let colliders: [Collider]
            
            public struct Collider: Codable {
                public let offset: Vector3
                public let radius: Double
            }
        }
    }

    struct Vector3: Codable {
        public let x, y, z: Double
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            x = try decodeDouble(key: .x, container: container)
            y = try decodeDouble(key: .y, container: container)
            z = try decodeDouble(key: .z, container: container)
        }
    }
}

private func decodeDouble<T: CodingKey>(key: T, container: KeyedDecodingContainer<T>) throws -> Double {
    return try (try? container.decode(Double.self, forKey: key)) ?? Double(try container.decode(Int.self, forKey: key))
}
