import Foundation

public struct VRM1 {
    /// The `VRMC_vrm` spec versions this type models.
    public static func supports(specVersion: String) -> Bool {
        specVersion == "1.0" || specVersion == "1.0-beta"
    }

    /// The underlying glTF document, which carries the model's glTF and the
    /// binary resources it is drawn from.
    public let document: GLTFDocument
    public let specVersion: String
    public let meta: Meta
    public let humanoid: Humanoid
    public let firstPerson: FirstPerson?
    public let lookAt: LookAt?
    public let expressions: Expressions?
    public let springBone: SpringBone?
    public let extensions: CodableAny?
    public let extras: CodableAny?

    /// Initialize from VRM 1.0 data. `rootDirectory` is the base directory for
    /// external resources.
    public init(data: Data, rootDirectory: URL? = nil) throws {
        try self.init(document: GLTFDocument(data: data, rootDirectory: rootDirectory))
    }

    /// Initialize from an already-loaded document, so that deciding which
    /// version a file is does not mean parsing it twice.
    public init(document: GLTFDocument) throws {
        self.document = document

        let extensions = try document.gltf.rootExtensions()
        let vrm = try extensions["VRMC_vrm"] ??? .keyNotFound("VRMC_vrm")
        specVersion = try vrm["specVersion"] as? String ??? .dataInconsistent("VRMC_vrm.specVersion is missing or not a string")
        guard VRM1.supports(specVersion: specVersion) else {
            throw VRMError._notSupported("VRMC_vrm specVersion \(specVersion)")
        }

        meta = try vrm.decodeJSON(Meta.self, forKey: "meta")
        humanoid = try vrm.decodeJSON(Humanoid.self, forKey: "humanoid")
        firstPerson = try vrm.decodeJSONIfPresent(FirstPerson.self, forKey: "firstPerson")
        lookAt = try vrm.decodeJSONIfPresent(LookAt.self, forKey: "lookAt")
        expressions = try vrm.decodeJSONIfPresent(Expressions.self, forKey: "expressions")
        springBone = try extensions.decodeJSONIfPresent(SpringBone.self, forKey: "VRMC_springBone")
        if let springBone, !SpringBone.supports(specVersion: springBone.specVersion) {
            throw VRMError._notSupported("VRMC_springBone specVersion \(springBone.specVersion)")
        }
        self.extensions = try vrm.decodeJSONIfPresent(CodableAny.self, forKey: "extensions")
        extras = try vrm.decodeJSONIfPresent(CodableAny.self, forKey: "extras")
    }
}

// VRMC_vrm
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
        public let extensions: CodableAny?
        public let extras: CodableAny?

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

    struct Humanoid: Codable {
        public let humanBones: HumanBones
        public let extensions: CodableAny?
        public let extras: CodableAny?

        /// The nodes the rig maps its bones to.
        ///
        /// VRM 1.0 gives every bone its own JSON property, decoded into one
        /// dictionary so that a bone is looked up rather than switched on and
        /// both VRM versions read as the same shape. A property VRM does not
        /// define is ignored rather than failing the parse.
        public struct HumanBones: Codable {
            public let bones: [HumanoidBone: HumanBone]

            /// The node the rig maps `bone` to, or nil when it does not rig it.
            public subscript(bone: HumanoidBone) -> HumanBone? { bones[bone] }

            /// The bones VRM 1.0 requires of every humanoid.
            static let required: [HumanoidBone] = [
                .hips, .spine, .head,
                .leftUpperLeg, .leftLowerLeg, .leftFoot,
                .rightUpperLeg, .rightLowerLeg, .rightFoot,
                .leftUpperArm, .leftLowerArm, .leftHand,
                .rightUpperArm, .rightLowerArm, .rightHand,
            ]

            public init(bones: [HumanoidBone: HumanBone]) {
                self.bones = bones
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: AnyCodingKey.self)
                bones = try HumanoidBone.allCases.reduce(into: [:]) { bones, bone in
                    guard let key = AnyCodingKey(stringValue: bone.rawValue),
                          container.contains(key) else { return }
                    bones[bone] = try container.decode(HumanBone.self, forKey: key)
                }
                if let missing = Self.required.first(where: { bones[$0] == nil }) {
                    throw VRMError.keyNotFound("humanBones.\(missing.rawValue)")
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: AnyCodingKey.self)
                for bone in HumanoidBone.allCases {
                    guard let humanBone = bones[bone],
                          let key = AnyCodingKey(stringValue: bone.rawValue) else { continue }
                    try container.encode(humanBone, forKey: key)
                }
            }

            public struct HumanBone: Codable {
                public let node: Int
                public let extensions: CodableAny?
                public let extras: CodableAny?
            }
        }
    }

    struct FirstPerson: Codable {
        public let meshAnnotations: [MeshAnnotation]
        public let extensions: CodableAny?
        public let extras: CodableAny?

        // meshAnnotations is optional in practice, so decode it leniently.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meshAnnotations = try container.decodeIfPresent([MeshAnnotation].self, forKey: .meshAnnotations) ?? []
            extensions = try container.decodeIfPresent(CodableAny.self, forKey: .extensions)
            extras = try container.decodeIfPresent(CodableAny.self, forKey: .extras)
        }
        
        public struct MeshAnnotation: Codable {
            public let type: FirstPersonType
            public let node: Int
            public let extensions: CodableAny?
            public let extras: CodableAny?
        }

        public enum FirstPersonType: String, Codable {
            case auto
            case both
            case thirdPersonOnly
            case firstPersonOnly
        }
    }

    struct LookAt: Codable {
        public let offsetFromHeadBone:[Double]
        public let type: LookAtType
        public let rangeMapHorizontalInner: LookAtRangeMap
        public let rangeMapHorizontalOuter: LookAtRangeMap
        public let rangeMapVerticalDown: LookAtRangeMap
        public let rangeMapVerticalUp: LookAtRangeMap
        public let extensions: CodableAny?
        public let extras: CodableAny?
        
        public enum LookAtType: String, Codable {
            case bone
            case expression
        }

        public struct LookAtRangeMap: Codable {
            public let inputMaxValue: Double
            public let outputScale: Double
            public let extensions: CodableAny?
            public let extras: CodableAny?
        }
    }
    
    struct Expressions: Codable {
        public let preset: Preset?
        public let custom: CodableAny?
        public let extensions: CodableAny?
        public let extras: CodableAny?

        public struct Preset: Codable {
            public let happy: Expression?
            public let angry: Expression?
            public let sad: Expression?
            public let relaxed: Expression?
            public let surprised: Expression?
            public let aa: Expression?
            public let ih: Expression?
            public let ou: Expression?
            public let ee: Expression?
            public let oh: Expression?
            public let blink: Expression?
            public let blinkLeft: Expression?
            public let blinkRight: Expression?
            public let lookUp: Expression?
            public let lookDown: Expression?
            public let lookLeft: Expression?
            public let lookRight: Expression?
            public let neutral: Expression?
        }

        public struct Expression: Codable {
            public let morphTargetBinds: [MorphTargetBind]?
            public let materialColorBinds: [MaterialColorBind]?
            public let textureTransformBinds: [TextureTransformBind]?
            public let isBinary: Bool?
            public let overrideBlink: ExpressionOverrideType?
            public let overrideLookAt: ExpressionOverrideType?
            public let overrideMouth: ExpressionOverrideType?
            public let extensions: CodableAny?
            public let extras: CodableAny?

            public struct MorphTargetBind: Codable {
                public let node: Int
                public let index: Int
                public let weight: Double
                public let extensions: CodableAny?
                public let extras: CodableAny?
            }

            public struct MaterialColorBind: Codable {
                public let material: Int
                public let type: MaterialColorType
                public let targetValue: [Double]
                public let extensions: CodableAny?
                public let extras: CodableAny?

                public enum MaterialColorType: String, Codable {
                    case color
                    case emissionColor
                    case shadeColor
                    case matcapColor
                    case rimColor
                    case outlineColor
                }
            }

            public struct TextureTransformBind: Codable {
                public let material: Int
                public let scale: [Double]?
                public let offset: [Double]?
                public let extensions: CodableAny?
                public let extras: CodableAny?
            }

            public enum ExpressionOverrideType: String, Codable {
                case none
                case block
                case blend
            }
        }
    }
}

// VRMC_springBone
extension VRM1 {
    public struct SpringBone: Codable {
        /// The `VRMC_springBone` spec versions this type models. The extension
        /// carries its own version rather than the model's.
        public static func supports(specVersion: String) -> Bool {
            specVersion == "1.0" || specVersion == "1.0-beta"
        }

        public let specVersion: String
        public let colliders: [Collider]?
        public let colliderGroups: [ColliderGroup]?
        public let springs: [Spring]?
        public let extensions: CodableAny?
        public let extras: CodableAny?

        public struct Collider: Codable {
            public let node: Int
            public let shape: Shape
            public let extensions: CodableAny?
            public let extras: CodableAny?

            public struct Shape: Codable {
                public let sphere: ColliderShapeSphere?
                public let capsule: ColliderShapeCapsule?
                public let extensions: CodableAny?
                public let extras: CodableAny?

                public struct ColliderShapeSphere: Codable {
                    public let offset: [Double]
                    public let radius: Double
                }

                public struct ColliderShapeCapsule: Codable {
                    public let offset: [Double]
                    public let radius: Double
                    public let tail: [Double]
                }
            }
        }

        public struct ColliderGroup: Codable {
            public let colliders: [Int]
            public let extensions: CodableAny?
            public let extras: CodableAny?
        }

        public struct Spring: Codable {
            public let name: String?
            public let joints: [Joint]
            public let colliderGroups: [Int]?
            public let center: Int?
            public let extensions: CodableAny?
            public let extras: CodableAny?

            public struct Joint: Codable {
                public let node: Int
                public let hitRadius: Double?
                public let stiffness: Double?
                public let gravityPower: Double?
                public let gravityDir: [Double]?
                public let dragForce: Double?
                public let extensions: CodableAny?
                public let extras: CodableAny?
            }
        }
    }
}
