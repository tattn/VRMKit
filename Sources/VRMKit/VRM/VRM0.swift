import Foundation

public struct VRM0: Sendable {
    /// The underlying glTF document, which carries the model's glTF and the
    /// binary resources it is drawn from.
    public let document: GLTFDocument
    public let meta: Meta
    public let version: String?
    public let materialProperties: [MaterialProperty]
    public let humanoid: Humanoid
    public let blendShapeMaster: BlendShapeMaster
    public let firstPerson: FirstPerson
    public let secondaryAnimation: SecondaryAnimation

    /// Initialize from VRM 0.x data. `rootDirectory` is the base directory for
    /// external resources.
    public init(data: Data, rootDirectory: URL? = nil) throws {
        try self.init(document: GLTFDocument(data: data, rootDirectory: rootDirectory))
    }

    /// Initialize from an already-loaded document, so that deciding which
    /// version a file is does not mean parsing it twice.
    public init(document: GLTFDocument) throws {
        self.document = document

        let extensions = try document.gltf.rootExtensions()

        let vrm = try extensions["VRM"] ??? .keyNotFound("VRM")

        meta = try vrm.decodeJSON(Meta.self, forKey: "meta")
        version = vrm.string("version")
        // Absent in some files, and in `prune()` output once every material died
        materialProperties = try vrm.decodeJSONIfPresent([MaterialProperty].self, forKey: "materialProperties") ?? []
        humanoid = try vrm.decodeJSON(Humanoid.self, forKey: "humanoid")
        blendShapeMaster = try vrm.decodeJSON(BlendShapeMaster.self, forKey: "blendShapeMaster")
        firstPerson = try vrm.decodeJSON(FirstPerson.self, forKey: "firstPerson")
        // Absent in a model that swings nothing, `prune()` output among them
        secondaryAnimation = try vrm.decodeJSONIfPresent(SecondaryAnimation.self, forKey: "secondaryAnimation")
            ?? SecondaryAnimation()
    }
}

public extension VRM0 {
    /// The Unity material settings describing the material at `index`. VRM 0.x
    /// writes `materialProperties` as an array parallel to the glTF `materials`,
    /// so the index pairs the two.
    func materialProperty(at index: Int) -> MaterialProperty? {
        materialProperties[safe: index]
    }
}

public extension VRM {
    /// The VRM 0.x material settings for the material at `index`, or nil for a
    /// VRM 1.0 model, which describes its materials on the materials.
    func vrm0MaterialProperty(at index: Int) -> VRM0.MaterialProperty? {
        guard case .v0(let vrm0) = self else { return nil }
        return vrm0.materialProperty(at: index)
    }
}

public extension VRM0 {
    struct Meta: Codable, Sendable {
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

    struct MaterialProperty: Codable, Sendable {
        public let name: String
        public let shader: String
        public let renderQueue: Int
        /// Unity's `float` shader properties, `_Cutoff` and `_BlendMode` among
        /// them.
        public let floatProperties: [String: Float]
        public let keywordMap: [String: Bool]
        public let tagMap: [String: String]
        public let textureProperties: [String: Int]
        /// Unity's `vector` shader properties: a colour, or the `_MainTex`
        /// offset and scale pair.
        public let vectorProperties: [String: [Float]]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            shader = try container.decode(String.self, forKey: .shader)
            renderQueue = try container.decode(Int.self, forKey: .renderQueue)
            keywordMap = try container.decode([String: Bool].self, forKey: .keywordMap)
            tagMap = try container.decode([String: String].self, forKey: .tagMap)
            textureProperties = try container.decode([String: Int].self, forKey: .textureProperties)
            // A property whose value is of no use to a renderer is dropped
            // rather than failing the load of the whole model.
            floatProperties = try container.decode([String: JSONValue].self, forKey: .floatProperties)
                .compactMapValues(\.floatValue)
            vectorProperties = try container.decode([String: JSONValue].self, forKey: .vectorProperties)
                .compactMapValues { $0.arrayValue?.compactMap(\.floatValue) }
        }
    }

    struct Humanoid: Codable, Sendable {
        public let armStretch: Double
        public let feetSpacing: Double
        public let hasTranslationDoF: Bool
        public let legStretch: Double
        public let lowerArmTwist: Double
        public let lowerLegTwist: Double
        public let upperArmTwist: Double
        public let upperLegTwist: Double
        public let humanBones: [HumanBone]

        public struct HumanBone: Codable, Sendable {
            public let bone: String
            public let node: Int
            public let useDefaultValues: Bool
        }
    }

    struct BlendShapeMaster: Codable, Sendable {
        public let blendShapeGroups: [BlendShapeGroup]
        public struct BlendShapeGroup: Codable, Sendable {
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
            public struct Bind: Codable, Sendable {
                public let index: Int
                public let mesh: Int
                public let weight: Double
            }
            public struct MaterialValueBind: Codable, Sendable {
                public let materialName: String
                public let propertyName: String
                public let targetValue: [Double]
            }
        }
    }

    struct FirstPerson: Codable, Sendable {
        public let firstPersonBone: Int
        public let firstPersonBoneOffset: Vector3
        /// Absent in files with nothing annotated, `prune()` output among them
        public let meshAnnotations: [MeshAnnotation]
        public let lookAtTypeName: LookAtType

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            firstPersonBone = try container.decode(Int.self, forKey: .firstPersonBone)
            firstPersonBoneOffset = try container.decode(Vector3.self, forKey: .firstPersonBoneOffset)
            meshAnnotations = try container.decodeIfPresent([MeshAnnotation].self, forKey: .meshAnnotations) ?? []
            lookAtTypeName = try container.decode(LookAtType.self, forKey: .lookAtTypeName)
        }

        public struct MeshAnnotation: Codable, Sendable {
            public let firstPersonFlag: String
            public let mesh: Int
        }
        public enum LookAtType: String, Codable, Sendable {
            case none = "None"
            case bone = "Bone"
            case blendShape = "BlendShape"
        }
    }

    struct SecondaryAnimation: Codable, Sendable {
        /// Either array is absent in a model that states nothing for it, and
        /// both are in one that swings nothing at all.
        public let boneGroups: [BoneGroup]
        public let colliderGroups: [ColliderGroup]

        init(boneGroups: [BoneGroup] = [], colliderGroups: [ColliderGroup] = []) {
            self.boneGroups = boneGroups
            self.colliderGroups = colliderGroups
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            boneGroups = try container.decodeIfPresent([BoneGroup].self, forKey: .boneGroups) ?? []
            colliderGroups = try container.decodeIfPresent([ColliderGroup].self, forKey: .colliderGroups) ?? []
        }

        public struct BoneGroup: Codable, Sendable {
            public let bones: [Int]
            public let center: Int
            public let colliderGroups: [Int]
            public let comment: String?
            public let dragForce: Double
            public let gravityDir: Vector3
            public let gravityPower: Double
            public let hitRadius: Double
            public let stiffiness: Double
        }

        public struct ColliderGroup: Codable, Sendable {
            public let node: Int
            public let colliders: [Collider]

            public struct Collider: Codable, Sendable {
                public let offset: Vector3
                public let radius: Double
            }
        }
    }

    struct Vector3: Codable, Sendable {
        public let x, y, z: Double
    }
}
