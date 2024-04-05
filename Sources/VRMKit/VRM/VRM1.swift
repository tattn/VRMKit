//
//  VRM1.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

public struct VRM1: VRMFileProtocol {
    public let gltf: BinaryGLTF
    public let specVersion: String
    public let meta: Meta
    //public let version: String?
    //public let materialProperties: [MaterialProperty]
    public let humanoid: Humanoid
    //public let blendShapeMaster: BlendShapeMaster
    public let firstPerson: FirstPerson?
    //public let secondaryAnimation: SecondaryAnimation
    public let lookAt: LookAt?

    //public let materialPropertyNameMap: [String: MaterialProperty]

    public init(data: Data) throws {
        gltf = try BinaryGLTF(data: data)

        let rawExtensions = try gltf.jsonData.extensions ??? .keyNotFound("extensions")
        let extensions = try rawExtensions.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")
        let vrm = try extensions["VRMC_vrm"] ??? .keyNotFound("VRMC_vrm")
        specVersion = vrm["specVersion"] as! String

        let decoder = DictionaryDecoder()
        meta = try decoder.decode(Meta.self, from: try vrm["meta"] ??? .keyNotFound("meta"))
        //version = vrm["version"] as? String
        //materialProperties = try decoder.decode([MaterialProperty].self, from: try vrm["materialProperties"] ??? .keyNotFound("materialProperties"))
        humanoid = try decoder.decode(Humanoid.self, from: try vrm["humanoid"] ??? .keyNotFound("humanoid"))
        //blendShapeMaster = try decoder.decode(BlendShapeMaster.self, from: try vrm["blendShapeMaster"] ??? .keyNotFound("blendShapeMaster"))
        let containFirstPerson = vrm.keys.contains("firstPerson")
        firstPerson = containFirstPerson ? try decoder.decode(FirstPerson.self, from: vrm["firstPerson"] ?? "".data(using: .utf8)!) : nil
        //secondaryAnimation = try decoder.decode(SecondaryAnimation.self, from: try vrm["secondaryAnimation"] ??? .keyNotFound("secondaryAnimation"))

        //materialPropertyNameMap = materialProperties.reduce(into: [:]) { $0[$1.name] = $1 }
        let containLookAt = vrm.keys.contains("lookAt")
        lookAt = containLookAt ? try decoder.decode(LookAt.self, from: vrm["lookAt"] ?? "".data(using: .utf8)!) : nil
    }
}

public extension VRM1 {
    struct Meta: Codable {
        public let name: String
        public let version: String?
        public let authors: [String]
        public let copyrightInformation: String?
        public let contactInformation: String?
        public let references: [String]?
        public let thirdPartyLicenses: String?
        public let thumbnailImage: Int?
        public let licenseUrl: String
        public let avatarPermission: AvatarPermissionType?
        public let allowExcessivelyViolentUsage: Bool?
        public let allowExcessivelySexualUsage: Bool?
        public let commercialUsage: CommercialUsageType?
        public let allowPoliticalOrReligiousUsage: Bool?
        public let allowAntisocialOrHateUsage: Bool?
        public let creditNotation: CreditNotationType?
        public let allowRedistribution: Bool?
        public let modification: ModificationType?
        public let otherLicenseUrl: String?

        public enum AvatarPermissionType: String, Codable {
            case onlyAuthor
            case onlySeparatelyLicensedPerson
            case everyone
        }

        public enum CommercialUsageType: String, Codable {
            case personalNonProfit
            case personalProfit
            case corporation
        }

        public enum CreditNotationType: String, Codable {
            case required
            case unnecessary
        }

        public enum ModificationType: String, Codable {
            case prohibited
            case allowModification
            case allowModificationRedistribution
        }
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
        public let humanBones: HumanBones

        public struct HumanBones: Codable{
            public let hips: HumanBone
            public let spine: HumanBone
            public let chest: HumanBone?
            public let upperChest: HumanBone?
            public let neck: HumanBone?
            public let head: HumanBone
            public let leftEye: HumanBone?
            public let rightEye: HumanBone?
            public let jaw: HumanBone?
            public let leftUpperLeg: HumanBone
            public let leftLowerLeg: HumanBone
            public let leftFoot:HumanBone
            public let leftToes: HumanBone?
            public let rightUpperLeg: HumanBone
            public let rightLowerLeg: HumanBone
            public let rightFoot: HumanBone
            public let rightToes: HumanBone?
            public let leftShoulder: HumanBone?
            public let leftUpperArm: HumanBone
            public let leftLowerArm: HumanBone
            public let leftHand: HumanBone
            public let rightShoulder: HumanBone?
            public let rightUpperArm: HumanBone
            public let rightLowerArm: HumanBone
            public let rightHand: HumanBone
            public let leftThumbMetacarpal: HumanBone?
            public let leftThumbProximal: HumanBone?
            public let leftThumbDistal: HumanBone?
            public let leftIndexProximal: HumanBone?
            public let leftIndexIntermediate: HumanBone?
            public let leftIndexDistal: HumanBone?
            public let leftMiddleProximal: HumanBone?
            public let leftMiddleIntermediate: HumanBone?
            public let leftMiddleDistal: HumanBone?
            public let leftRingProximal: HumanBone?
            public let leftRingIntermediate: HumanBone?
            public let leftRingDistal: HumanBone?
            public let leftLittleProximal: HumanBone?
            public let leftLittleIntermediate: HumanBone?
            public let leftLittleDistal: HumanBone?
            public let rightThumbMetacarpal: HumanBone?
            public let rightThumbProximal: HumanBone?
            public let rightThumbDistal: HumanBone?
            public let rightIndexProximal: HumanBone?
            public let rightIndexIntermediate: HumanBone?
            public let rightIndexDistal: HumanBone?
            public let rightMiddleProximal: HumanBone?
            public let rightMiddleIntermediate: HumanBone?
            public let rightMiddleDistal: HumanBone?
            public let rightRingProximal: HumanBone?
            public let rightRingIntermediate: HumanBone?
            public let rightRingDistal: HumanBone?
            public let rightLittleProximal: HumanBone?
            public let rightLittleIntermediate: HumanBone?
            public let rightLittleDistal: HumanBone?
            
            public struct HumanBone: Codable {
                public let node: Int
            }
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
        public let meshAnnotations: [MeshAnnotation]
        
        public struct MeshAnnotation: Codable {
            public let type: FirstPersonType
            public let node: Int
        }

        public enum FirstPersonType: String, Codable {
            case auto
            case both
            case thirdPersonOnly
            case firstPersonOnly
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

    struct LookAt: Codable {
        public let offsetFromHeadBone:[IntOrDouble]
        public let type: LookAtType
        public let rangeMapHorizontalInner: LookAtRangeMap
        public let rangeMapHorizontalOuter: LookAtRangeMap
        public let rangeMapVerticalDown: LookAtRangeMap
        public let rangeMapVerticalUp: LookAtRangeMap

        public enum IntOrDouble: Codable {
            case int(Int)
            case double(Double)

            public func getValue() -> Double {
                switch self {
                    case .int(let v):
                        return Double(v)
                    case .double(let v):
                        return v
                }
            }

            public init(from decoder: Decoder) throws {
                if let i = try? decoder.singleValueContainer().decode(Int.self) {
                    self = .int(i)
                    return
                }

                if let d = try? decoder.singleValueContainer().decode(Double.self) {
                    self = .double(d)
                    return
                }

                throw Error.couldNotDecodeIntOrDouble
            }

            public enum Error: Swift.Error {
                case couldNotDecodeIntOrDouble
            }
        }

        public enum LookAtType: String, Codable {
            case bone
            case expression
        }

        public struct LookAtRangeMap: Codable {
            public let inputMaxValue: Double
            public let outputScale: Double

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                inputMaxValue = try decodeDouble(key: .inputMaxValue, container: container)
                outputScale = try decodeDouble(key: .outputScale, container: container)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            offsetFromHeadBone = try container.decode([IntOrDouble].self, forKey: .offsetFromHeadBone)
            type = try container.decode(LookAtType.self, forKey: .type)
            rangeMapHorizontalInner = try container.decode(LookAtRangeMap.self, forKey: .rangeMapHorizontalInner)
            rangeMapHorizontalOuter = try container.decode(LookAtRangeMap.self, forKey: .rangeMapHorizontalOuter)
            rangeMapVerticalDown = try container.decode(LookAtRangeMap.self, forKey: .rangeMapVerticalDown)
            rangeMapVerticalUp = try container.decode(LookAtRangeMap.self, forKey: .rangeMapVerticalUp)
        }
    }
}

private func decodeDouble<T: CodingKey>(key: T, container: KeyedDecodingContainer<T>) throws -> Double {
    return try (try? container.decode(Double.self, forKey: key)) ?? Double(try container.decode(Int.self, forKey: key))
}
