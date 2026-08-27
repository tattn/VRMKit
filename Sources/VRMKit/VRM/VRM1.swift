import Foundation

public struct VRM1: Sendable {
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
    public let extensions: JSONValue?
    public let extras: JSONValue?

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
        specVersion = try vrm.string("specVersion")
            ??? .dataInconsistent("VRMC_vrm.specVersion is missing or not a string")
        guard VRM1.supports(specVersion: specVersion) else {
            throw VRMError._notSupported("VRMC_vrm specVersion \(specVersion)")
        }

        meta = try vrm.decodeJSON(Meta.self, forKey: "meta")
        humanoid = try vrm.decodeJSON(Humanoid.self, forKey: "humanoid")
        firstPerson = try vrm.decodeJSONIfPresent(FirstPerson.self, forKey: "firstPerson")
        lookAt = try vrm.decodeJSONIfPresent(LookAt.self, forKey: "lookAt")
        expressions = try vrm.decodeJSONIfPresent(Expressions.self, forKey: "expressions")
        springBone = try extensions["VRMC_springBone"]?.decode(SpringBone.self)
        if let springBone, !SpringBone.supports(specVersion: springBone.specVersion) {
            throw VRMError._notSupported("VRMC_springBone specVersion \(springBone.specVersion)")
        }
        self.extensions = try vrm.decodeJSONIfPresent(JSONValue.self, forKey: "extensions")
        extras = try vrm.decodeJSONIfPresent(JSONValue.self, forKey: "extras")
    }
}

// VRMC_vrm
public extension VRM1 {
    struct Meta: Codable, Sendable {
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
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public enum AvatarPermissionType: String, Codable, Sendable {
            case onlyAuthor
            case onlySeparatelyLicensedPerson
            case everyone
        }

        public enum CommercialUsageType: String, Codable, Sendable {
            case personalNonProfit
            case personalProfit
            case corporation
        }

        public enum CreditNotationType: String, Codable, Sendable {
            case required
            case unnecessary
        }

        public enum ModificationType: String, Codable, Sendable {
            case prohibited
            case allowModification
            case allowModificationRedistribution
        }
    }

    struct Humanoid: Codable, Sendable {
        public let humanBones: HumanBones
        public let extensions: JSONValue?
        public let extras: JSONValue?

        /// The nodes the rig maps its bones to.
        ///
        /// VRM 1.0 gives every bone its own JSON property, decoded into one
        /// dictionary so that both VRM versions read as the same shape. A property
        /// VRM does not define is ignored rather than failing the parse.
        public struct HumanBones: Codable, Sendable {
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

            public struct HumanBone: Codable, Sendable {
                public let node: Int
                public let extensions: JSONValue?
                public let extras: JSONValue?
            }
        }
    }

    struct FirstPerson: Codable, Sendable {
        public let meshAnnotations: [MeshAnnotation]
        public let extensions: JSONValue?
        public let extras: JSONValue?

        // meshAnnotations is optional in practice, so decode it leniently.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meshAnnotations = try container.decodeIfPresent([MeshAnnotation].self, forKey: .meshAnnotations) ?? []
            extensions = try container.decodeIfPresent(JSONValue.self, forKey: .extensions)
            extras = try container.decodeIfPresent(JSONValue.self, forKey: .extras)
        }
        
        public struct MeshAnnotation: Codable, Sendable {
            public let type: FirstPersonType
            public let node: Int
            public let extensions: JSONValue?
            public let extras: JSONValue?
        }

        public enum FirstPersonType: String, Codable, Sendable {
            case auto
            case both
            case thirdPersonOnly
            case firstPersonOnly
        }
    }

    struct LookAt: Codable, Sendable {
        public let offsetFromHeadBone:[Double]
        public let type: LookAtType
        public let rangeMapHorizontalInner: LookAtRangeMap
        public let rangeMapHorizontalOuter: LookAtRangeMap
        public let rangeMapVerticalDown: LookAtRangeMap
        public let rangeMapVerticalUp: LookAtRangeMap
        public let extensions: JSONValue?
        public let extras: JSONValue?
        
        public enum LookAtType: String, Codable, Sendable {
            case bone
            case expression
        }

        public struct LookAtRangeMap: Codable, Sendable {
            public let inputMaxValue: Double
            public let outputScale: Double
            public let extensions: JSONValue?
            public let extras: JSONValue?
        }
    }
    
    struct Expressions: Codable, Sendable {
        public let preset: Preset?
        /// The expressions the model names itself.
        public let custom: [String: Expression]?
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public struct Preset: Codable, Sendable {
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

        public struct Expression: Codable, Sendable {
            public let morphTargetBinds: [MorphTargetBind]?
            public let materialColorBinds: [MaterialColorBind]?
            public let textureTransformBinds: [TextureTransformBind]?
            public let isBinary: Bool?
            public let overrideBlink: ExpressionOverrideType?
            public let overrideLookAt: ExpressionOverrideType?
            public let overrideMouth: ExpressionOverrideType?
            public let extensions: JSONValue?
            public let extras: JSONValue?

            public struct MorphTargetBind: Codable, Sendable {
                public let node: Int
                public let index: Int
                public let weight: Double
                public let extensions: JSONValue?
                public let extras: JSONValue?
            }

            public struct MaterialColorBind: Codable, Sendable {
                public let material: Int
                public let type: MaterialColorType
                public let targetValue: [Double]
                public let extensions: JSONValue?
                public let extras: JSONValue?

                public enum MaterialColorType: String, Codable, Sendable {
                    case color
                    case emissionColor
                    case shadeColor
                    case matcapColor
                    case rimColor
                    case outlineColor
                }
            }

            public struct TextureTransformBind: Codable, Sendable {
                public let material: Int
                public let scale: [Double]?
                public let offset: [Double]?
                public let extensions: JSONValue?
                public let extras: JSONValue?
            }

            public enum ExpressionOverrideType: String, Codable, Sendable {
                case none
                case block
                case blend
            }
        }
    }
}

// VRMC_springBone
extension VRM1 {
    public struct SpringBone: Codable, Sendable {
        /// The `VRMC_springBone` spec versions this type models. The extension
        /// carries its own version rather than the model's.
        public static func supports(specVersion: String) -> Bool {
            specVersion == "1.0" || specVersion == "1.0-beta"
        }

        public let specVersion: String
        public let colliders: [Collider]?
        public let colliderGroups: [ColliderGroup]?
        public let springs: [Spring]?
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public struct Collider: Codable, Sendable {
            public let node: Int
            public let shape: Shape
            public let extensions: JSONValue?
            public let extras: JSONValue?

            /// What a collider collides as. One stating neither shape would
            /// still collide, at whatever hit radius a joint brings.
            public enum Shape: Codable, Sendable {
                case sphere(ColliderShapeSphere)
                case capsule(ColliderShapeCapsule)

                private enum CodingKeys: String, CodingKey {
                    case sphere, capsule
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let shapes: [Shape] = [
                        try container.decodeIfPresent(ColliderShapeSphere.self, forKey: .sphere).map(Shape.sphere),
                        try container.decodeIfPresent(ColliderShapeCapsule.self, forKey: .capsule).map(Shape.capsule),
                    ].compactMap { $0 }
                    guard shapes.count == 1, let shape = shapes.first else {
                        throw VRMError._dataInconsistent(
                            "a VRMC_springBone collider is either a sphere or a capsule, and this one states "
                            + "neither or both"
                        )
                    }
                    self = shape
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case .sphere(let sphere): try container.encode(sphere, forKey: .sphere)
                    case .capsule(let capsule): try container.encode(capsule, forKey: .capsule)
                    }
                }

                public struct ColliderShapeSphere: Codable, Sendable {
                    public let offset: [Double]
                    public let radius: Double
                }

                public struct ColliderShapeCapsule: Codable, Sendable {
                    public let offset: [Double]
                    public let radius: Double
                    public let tail: [Double]
                }
            }
        }

        public struct ColliderGroup: Codable, Sendable {
            public let colliders: [Int]
            public let extensions: JSONValue?
            public let extras: JSONValue?
        }

        public struct Spring: Codable, Sendable {
            public let name: String?
            public let joints: [Joint]
            public let colliderGroups: [Int]?
            public let center: Int?
            public let extensions: JSONValue?
            public let extras: JSONValue?

            public struct Joint: Codable, Sendable {
                public let node: Int
                public let hitRadius: Double?
                public let stiffness: Double?
                public let gravityPower: Double?
                public let gravityDir: [Double]?
                public let dragForce: Double?
                public let extensions: JSONValue?
                public let extras: JSONValue?
            }
        }
    }
}
