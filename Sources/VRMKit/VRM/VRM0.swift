import Foundation
import simd

public struct VRM0: Sendable {
    /// The underlying glTF document, carrying the model's glTF and binary resources.
    public let document: GLTFDocument
    public let meta: Meta
    public let version: String?
    public let materialProperties: [MaterialProperty]
    public let humanoid: Humanoid
    public let blendShapeMaster: BlendShapeMaster
    public let firstPerson: FirstPerson?
    public let secondaryAnimation: SecondaryAnimation

    /// Initialize from VRM 0.x data, resolving external resources against `rootDirectory`.
    public init(data: Data, rootDirectory: URL? = nil) throws {
        try self.init(document: GLTFDocument(data: data, rootDirectory: rootDirectory))
    }

    /// Initialize from an already-loaded document, so deciding a file's version does not
    /// mean parsing it twice. VRM 0.x leaves every part optional, so whatever a file leaves
    /// out reads as the defaults rather than failing the load.
    public init(document: GLTFDocument) throws {
        self.document = document

        let extensions = try document.gltf.rootExtensions()

        let vrm = try extensions["VRM"] ??? .keyNotFound("VRM")

        meta = try JSONValue.object(vrm["meta"]?.dictionaryValue ?? [:]).decode(Meta.self)
        version = vrm.string("version")
        materialProperties = try vrm.decodeJSONIfPresent([MaterialProperty].self, forKey: "materialProperties") ?? []
        humanoid = try JSONValue.object(vrm["humanoid"]?.dictionaryValue ?? [:]).decode(Humanoid.self)
        blendShapeMaster = try JSONValue.object(vrm["blendShapeMaster"]?.dictionaryValue ?? [:])
            .decode(BlendShapeMaster.self)
        firstPerson = try vrm.decodeJSONIfPresent(FirstPerson.self, forKey: "firstPerson")
        secondaryAnimation = try vrm.decodeJSONIfPresent(SecondaryAnimation.self, forKey: "secondaryAnimation")
            ?? SecondaryAnimation()
    }
}

public extension VRM0 {
    /// The Unity material settings describing the material at `index`. VRM 0.x writes
    /// `materialProperties` parallel to the glTF `materials`, so the index pairs the two.
    func materialProperty(at index: Int) -> MaterialProperty? {
        materialProperties[safe: index]
    }
}

public extension VRM {
    /// The VRM 0.x material settings for the material at `index`, or nil for a VRM 1.0
    /// model, which describes its materials on the materials themselves.
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
        public let violentUsage: String?
        public let sexualUsage: String?
        public let commercialUsage: String?
        public let otherPermissionUrl: String?

        public let licenseName: String?
        public let otherLicenseUrl: String?

        // 0.x really does spell "Ussage" this way; the typo stays out of the API.
        private enum CodingKeys: String, CodingKey {
            case title, author, contactInformation, reference, texture, version
            case allowedUserName
            case violentUsage = "violentUssageName"
            case sexualUsage = "sexualUssageName"
            case commercialUsage = "commercialUssageName"
            case otherPermissionUrl
            case licenseName, otherLicenseUrl
        }
    }

    struct MaterialProperty: Codable, Sendable {
        public let name: String
        public let shader: String
        /// Unity's render queue, 2000 (opaque geometry) where the file states none.
        public let renderQueue: Int
        /// Unity's `float` shader properties, `_Cutoff` and `_BlendMode` among them.
        public let floatProperties: [String: Float]
        public let keywordMap: [String: Bool]
        public let tagMap: [String: String]
        public let textureProperties: [String: Int]
        /// Unity's `vector` shader properties: a colour, or the `_MainTex` offset and scale pair.
        public let vectorProperties: [String: [Float]]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            shader = try container.decodeIfPresent(String.self, forKey: .shader) ?? ""
            renderQueue = try container.decodeIfPresent(Int.self, forKey: .renderQueue) ?? 2000
            keywordMap = try container.decodeIfPresent([String: Bool].self, forKey: .keywordMap) ?? [:]
            tagMap = try container.decodeIfPresent([String: String].self, forKey: .tagMap) ?? [:]
            textureProperties = try container.decodeIfPresent([String: Int].self, forKey: .textureProperties) ?? [:]
            // A property of no use to a renderer is dropped rather than failing the load.
            floatProperties = (try container.decodeIfPresent([String: JSONValue].self, forKey: .floatProperties) ?? [:])
                .compactMapValues(\.floatValue)
            vectorProperties = (try container.decodeIfPresent([String: JSONValue].self, forKey: .vectorProperties) ?? [:])
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

        // What a file leaves out reads as the UniVRM defaults.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            armStretch = try container.decodeIfPresent(Double.self, forKey: .armStretch) ?? 0.05
            feetSpacing = try container.decodeIfPresent(Double.self, forKey: .feetSpacing) ?? 0
            hasTranslationDoF = try container.decodeIfPresent(Bool.self, forKey: .hasTranslationDoF) ?? false
            legStretch = try container.decodeIfPresent(Double.self, forKey: .legStretch) ?? 0.05
            lowerArmTwist = try container.decodeIfPresent(Double.self, forKey: .lowerArmTwist) ?? 0.5
            lowerLegTwist = try container.decodeIfPresent(Double.self, forKey: .lowerLegTwist) ?? 0.5
            upperArmTwist = try container.decodeIfPresent(Double.self, forKey: .upperArmTwist) ?? 0.5
            upperLegTwist = try container.decodeIfPresent(Double.self, forKey: .upperLegTwist) ?? 0.5
            humanBones = try container.decodeIfPresent([HumanBone].self, forKey: .humanBones) ?? []
        }

        public struct HumanBone: Codable, Sendable {
            public let bone: String
            public let node: Int
            public let useDefaultValues: Bool

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                bone = try container.decode(String.self, forKey: .bone)
                node = try container.decode(Int.self, forKey: .node)
                useDefaultValues = try container.decodeIfPresent(Bool.self, forKey: .useDefaultValues) ?? true
            }
        }
    }

    struct BlendShapeMaster: Codable, Sendable {
        public let blendShapeGroups: [BlendShapeGroup]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            blendShapeGroups = try container.decodeIfPresent([BlendShapeGroup].self, forKey: .blendShapeGroups) ?? []
        }

        public struct BlendShapeGroup: Codable, Sendable {
            public let binds: [Bind]
            public let materialValues: [MaterialValueBind]
            public let name: String
            public let presetName: String
            public let isBinary: Bool

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                binds = try container.decodeIfPresent([Bind].self, forKey: .binds) ?? []
                materialValues = try container.decodeIfPresent([MaterialValueBind].self, forKey: .materialValues) ?? []
                name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
                presetName = try container.decodeIfPresent(String.self, forKey: .presetName) ?? ""
                isBinary = try container.decodeIfPresent(Bool.self, forKey: .isBinary) ?? false
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
        /// The node the first-person camera hangs off, or nil where the file
        /// states none, which VRM 0.x also spells as -1: the head bone stands in.
        public let firstPersonBone: Int?
        public let firstPersonBoneOffset: SIMD3<Float>
        /// Absent in files with nothing annotated, `prune()` output among them.
        public let meshAnnotations: [MeshAnnotation]
        public let lookAtTypeName: LookAtType
        /// How far an eye turns toward the nose for a gaze to its side, VRM 0.x's
        /// equivalent of the VRM 1.0 `rangeMapHorizontalInner`.
        public let lookAtHorizontalInner: DegreeMap?
        /// How far an eye turns away from the nose for a gaze to the other side.
        public let lookAtHorizontalOuter: DegreeMap?
        public let lookAtVerticalDown: DegreeMap?
        public let lookAtVerticalUp: DegreeMap?

        private enum CodingKeys: String, CodingKey {
            case firstPersonBone, firstPersonBoneOffset, meshAnnotations, lookAtTypeName
            case lookAtHorizontalInner, lookAtHorizontalOuter, lookAtVerticalDown, lookAtVerticalUp
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let bone = try container.decodeIfPresent(Int.self, forKey: .firstPersonBone)
            firstPersonBone = bone.flatMap { $0 >= 0 ? $0 : nil }
            firstPersonBoneOffset = try container.simd3Object(forKey: .firstPersonBoneOffset, default: .zero)
            meshAnnotations = try container.decodeIfPresent([MeshAnnotation].self, forKey: .meshAnnotations) ?? []
            // An unknown look-at type moves nothing, the way the spec's own "None" does.
            let lookAt = try container.decodeIfPresent(String.self, forKey: .lookAtTypeName)
            lookAtTypeName = lookAt.flatMap(LookAtType.init(rawValue:)) ?? .none
            lookAtHorizontalInner = try container.decodeIfPresent(DegreeMap.self, forKey: .lookAtHorizontalInner)
            lookAtHorizontalOuter = try container.decodeIfPresent(DegreeMap.self, forKey: .lookAtHorizontalOuter)
            lookAtVerticalDown = try container.decodeIfPresent(DegreeMap.self, forKey: .lookAtVerticalDown)
            lookAtVerticalUp = try container.decodeIfPresent(DegreeMap.self, forKey: .lookAtVerticalUp)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(firstPersonBone ?? -1, forKey: .firstPersonBone)
            try container.encodeSimd3Object(firstPersonBoneOffset, forKey: .firstPersonBoneOffset)
            try container.encode(meshAnnotations, forKey: .meshAnnotations)
            try container.encode(lookAtTypeName, forKey: .lookAtTypeName)
            try container.encodeIfPresent(lookAtHorizontalInner, forKey: .lookAtHorizontalInner)
            try container.encodeIfPresent(lookAtHorizontalOuter, forKey: .lookAtHorizontalOuter)
            try container.encodeIfPresent(lookAtVerticalDown, forKey: .lookAtVerticalDown)
            try container.encodeIfPresent(lookAtVerticalUp, forKey: .lookAtVerticalUp)
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

        /// One of the four curves a gaze angle passes through, which is how VRM 0.x
        /// states what VRM 1.0 states as a range map.
        public struct DegreeMap: Codable, Sendable {
            /// The Unity animation curve, as keyframes flattened into
            /// `time, value, inTangent, outTangent` quadruples.
            public let curve: [Float]?
            /// The input angle, in degrees, the curve's 0...1 domain spans.
            public let xRange: Double?
            /// What the curve's 0...1 output scales to.
            public let yRange: Double?
        }
    }

    struct SecondaryAnimation: Codable, Sendable {
        /// Either array is absent in a model that states nothing for it.
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
            /// The node swings settle relative to, or -1 for world space, in a field
            /// VRM 0.x always writes.
            public let center: Int
            public let colliderGroups: [Int]
            public let comment: String?
            public let dragForce: Double
            public let gravityDir: SIMD3<Float>
            public let gravityPower: Double
            public let hitRadius: Double
            public let stiffness: Double

            // 0.x really does spell "stiffiness" this way; the typo stays out of the API.
            // What a file leaves out reads as the UniVRM defaults.
            private enum CodingKeys: String, CodingKey {
                case bones, center, colliderGroups, comment, dragForce, gravityDir
                case gravityPower, hitRadius
                case stiffness = "stiffiness"
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                bones = try container.decodeIfPresent([Int].self, forKey: .bones) ?? []
                center = try container.decodeIfPresent(Int.self, forKey: .center) ?? -1
                colliderGroups = try container.decodeIfPresent([Int].self, forKey: .colliderGroups) ?? []
                comment = try container.decodeIfPresent(String.self, forKey: .comment)
                dragForce = try container.decodeIfPresent(Double.self, forKey: .dragForce) ?? 0.4
                gravityDir = try container.simd3Object(forKey: .gravityDir, default: SIMD3<Float>(0, -1, 0))
                gravityPower = try container.decodeIfPresent(Double.self, forKey: .gravityPower) ?? 0
                hitRadius = try container.decodeIfPresent(Double.self, forKey: .hitRadius) ?? 0.02
                stiffness = try container.decodeIfPresent(Double.self, forKey: .stiffness) ?? 1
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(bones, forKey: .bones)
                try container.encode(center, forKey: .center)
                try container.encode(colliderGroups, forKey: .colliderGroups)
                try container.encodeIfPresent(comment, forKey: .comment)
                try container.encode(dragForce, forKey: .dragForce)
                try container.encodeSimd3Object(gravityDir, forKey: .gravityDir)
                try container.encode(gravityPower, forKey: .gravityPower)
                try container.encode(hitRadius, forKey: .hitRadius)
                try container.encode(stiffness, forKey: .stiffness)
            }
        }

        public struct ColliderGroup: Codable, Sendable {
            public let node: Int
            public let colliders: [Collider]

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                node = try container.decodeIfPresent(Int.self, forKey: .node) ?? -1
                colliders = try container.decodeIfPresent([Collider].self, forKey: .colliders) ?? []
            }

            public struct Collider: Codable, Sendable {
                public let offset: SIMD3<Float>
                public let radius: Double

                private enum CodingKeys: String, CodingKey {
                    case offset, radius
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    offset = try container.simd3Object(forKey: .offset, default: .zero)
                    radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? 0
                }

                public func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encodeSimd3Object(offset, forKey: .offset)
                    try container.encode(radius, forKey: .radius)
                }
            }
        }
    }
}

// VRM 0.x spells a vector as an `{"x":, "y":, "z":}` object rather than an array.
private struct VRM0Vector3: Codable {
    let x, y, z: Double?

    init(_ value: SIMD3<Float>) {
        x = Double(value.x)
        y = Double(value.y)
        z = Double(value.z)
    }

    func simd(default defaultValue: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(x.map(Float.init) ?? defaultValue.x,
                     y.map(Float.init) ?? defaultValue.y,
                     z.map(Float.init) ?? defaultValue.z)
    }
}

private extension KeyedDecodingContainer {
    func simd3Object(forKey key: Key, default defaultValue: SIMD3<Float>) throws -> SIMD3<Float> {
        try decodeIfPresent(VRM0Vector3.self, forKey: key)?.simd(default: defaultValue) ?? defaultValue
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeSimd3Object(_ value: SIMD3<Float>, forKey key: Key) throws {
        try encode(VRM0Vector3(value), forKey: key)
    }
}
