import Foundation

/// VRM 0.x format data structure
public struct VRM0 {
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

        // VRM 0.x must have "VRM" extension
        let vrm = try extensions["VRM"] ??? .keyNotFound("VRM")

        meta = try vrm.decodeJSON(Meta.self, forKey: "meta")
        version = vrm["version"] as? String
        materialProperties = try vrm.decodeJSON([MaterialProperty].self, forKey: "materialProperties")
        humanoid = try vrm.decodeJSON(Humanoid.self, forKey: "humanoid")
        blendShapeMaster = try vrm.decodeJSON(BlendShapeMaster.self, forKey: "blendShapeMaster")
        firstPerson = try vrm.decodeJSON(FirstPerson.self, forKey: "firstPerson")
        secondaryAnimation = try vrm.decodeJSON(SecondaryAnimation.self, forKey: "secondaryAnimation")
    }
}

public extension VRM0 {
    /// The Unity material settings describing the material at `index`.
    ///
    /// VRM 0.x writes `materialProperties` as an array parallel to the glTF
    /// `materials`, so the index pairs the two. Two materials may share a name,
    /// which is why the name never does.
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
    }
}
