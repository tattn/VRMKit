import Foundation
import OSLog

// https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_vrm_animation-1.0

/// A parsed VRM animation (`.vrma`): a glTF asset whose root
/// `VRMC_vrm_animation` extension maps its nodes to humanoid bones,
/// expressions and look-at, so its standard glTF animation can be retargeted
/// onto any VRM model.
public struct VRMAnimation: Sendable {
    /// The `VRMC_vrm_animation` spec versions this type models: the released
    /// one, and the pre-release the reference implementation still reads.
    public static func supports(specVersion: String) -> Bool {
        specVersion == releasedSpecVersion || specVersion == draftSpecVersion
    }

    /// The only released version, and the one assumed for a file that declares
    /// none: exporters ship `.vrma` without the required `specVersion`.
    package static let releasedSpecVersion = "1.0"

    /// The pre-release version older exporters wrote.
    package static let draftSpecVersion = "1.0-draft"

    private static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "VRMAnimation")

    /// The underlying glTF document, which carries the animation samplers and
    /// their binary buffers.
    public let document: GLTFDocument
    public let specVersion: String
    public let humanoid: Humanoid?
    public let expressions: Expressions?
    public let lookAt: LookAt?
    public let extensions: JSONValue?
    public let extras: JSONValue?

    public init(document: GLTFDocument) throws {
        self.document = document

        let extensions = try document.gltf.rootExtensions()
        let vrma = try extensions["VRMC_vrm_animation"] ??? .keyNotFound("VRMC_vrm_animation")
        if let declared = vrma["specVersion"] {
            specVersion = try declared.stringValue
                ??? .dataInconsistent("VRMC_vrm_animation.specVersion is not a string")
            guard VRMAnimation.supports(specVersion: specVersion) else {
                throw VRMError._notSupported("VRMC_vrm_animation specVersion \(specVersion)")
            }
            if specVersion == VRMAnimation.draftSpecVersion {
                VRMAnimation.logger.warning("""
                This VRM animation declares the pre-release VRMC_vrm_animation.specVersion \
                \(VRMAnimation.draftSpecVersion, privacy: .public); \
                reading it as \(VRMAnimation.releasedSpecVersion, privacy: .public).
                """)
            }
        } else {
            specVersion = VRMAnimation.releasedSpecVersion
            VRMAnimation.logger.warning("""
            This VRM animation declares no VRMC_vrm_animation.specVersion, which the spec requires; \
            reading it as \(VRMAnimation.releasedSpecVersion, privacy: .public).
            """)
        }

        humanoid = try vrma.decodeJSONIfPresent(Humanoid.self, forKey: "humanoid")
        expressions = try vrma.decodeJSONIfPresent(Expressions.self, forKey: "expressions")
        lookAt = try vrma.decodeJSONIfPresent(LookAt.self, forKey: "lookAt")
        self.extensions = try vrma.decodeJSONIfPresent(JSONValue.self, forKey: "extensions")
        extras = try vrma.decodeJSONIfPresent(JSONValue.self, forKey: "extras")
    }

    /// Parses in-memory `.vrma` data, sniffing the GLB magic to pick the
    /// container format. `rootDirectory` is the base directory for external
    /// resources.
    public init(data: Data, rootDirectory: URL? = nil) throws {
        try self.init(document: GLTFDocument(data: data, rootDirectory: rootDirectory))
    }

    /// Loads a `.vrma` file. External resources resolve relative to the file's
    /// directory.
    public init(withURL url: URL) throws {
        try self.init(document: GLTFDocument(withURL: url))
    }

    /// Loads a bundled `.vrma` resource.
    public init(named name: String) throws {
        try self.init(document: GLTFDocument(named: name))
    }
}

// VRMC_vrm_animation
public extension VRMAnimation {
    struct Humanoid: Codable, Sendable {
        /// VRM humanoid bone name → the node its animation channels target.
        /// Keyed by the raw name, so bones this library does not know pass
        /// through instead of failing the parse.
        public let humanBones: [String: HumanBone]
        public let extensions: JSONValue?
        public let extras: JSONValue?

        public struct HumanBone: Codable, Sendable {
            public let node: Int
            public let extensions: JSONValue?
            public let extras: JSONValue?
        }
    }

    struct Expressions: Codable, Sendable {
        /// Preset expression name → its expression, keyed like `humanBones`.
        public let preset: [String: Expression]?
        public let custom: [String: Expression]?
        public let extensions: JSONValue?
        public let extras: JSONValue?
    }

    struct Expression: Codable, Sendable {
        /// The node whose translation X component carries the expression
        /// weight, clamped to 0...1.
        public let node: Int
        public let extensions: JSONValue?
        public let extras: JSONValue?
    }

    struct LookAt: Codable, Sendable {
        /// The node whose rotation carries the gaze direction.
        public let node: Int?
        public let offsetFromHeadBone: [Double]?
        public let extensions: JSONValue?
        public let extras: JSONValue?
    }
}
