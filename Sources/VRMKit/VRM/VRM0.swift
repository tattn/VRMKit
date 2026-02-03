import Foundation

/// VRM 0.x format data structure
public struct VRM0 {
    public let gltf: BinaryGLTF
    public let meta: Meta
    public let version: String?
    public let materialProperties: [MaterialProperty]
    public let humanoid: Humanoid
    public let blendShapeMaster: BlendShapeMaster
    public let firstPerson: FirstPerson
    public let secondaryAnimation: SecondaryAnimation

    public let materialPropertyNameMap: [String: MaterialProperty]

    /// Initialize from VRM 0.x data
    public init(data: Data) throws {
        gltf = try BinaryGLTF(data: data)

        let rawExtensions = try gltf.jsonData.extensions ??? .keyNotFound("extensions")
        let extensions = try rawExtensions.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")

        // VRM 0.x must have "VRM" extension
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

    /// Initialize by migrating from VRM 1.0
    public init(migratedFrom vrm1: VRM1) {
        self.gltf = vrm1.gltf
        self.version = vrm1.specVersion
        self.meta = Meta(vrm1: vrm1.meta)
        self.humanoid = Humanoid(vrm1: vrm1.humanoid)
        self.blendShapeMaster = BlendShapeMaster(vrm1: vrm1.expressions, gltf: vrm1.gltf)
        self.firstPerson = FirstPerson(vrm1: vrm1.firstPerson, lookAt: vrm1.lookAt)
        self.secondaryAnimation = SecondaryAnimation(vrm1: vrm1.springBone)
        self.materialProperties = (try? VRM0.migrateMaterials(gltf: vrm1.gltf, vrm1: vrm1)) ?? []
        self.materialPropertyNameMap = materialProperties.reduce(into: [:]) { $0[$1.name] = $1 }
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
