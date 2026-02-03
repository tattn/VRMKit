import Foundation

/// VRM data, supporting both VRM0 and VRM1 formats
public enum VRM {
    case v0(VRM0)
    case v1(VRM1)

    public init(data: Data) throws {
        let gltf = try BinaryGLTF(data: data)
        let rawExtensions = try gltf.jsonData.extensions ??? .keyNotFound("extensions")
        let extensions = try rawExtensions.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")

        if extensions.keys.contains("VRMC_vrm") {
            self = .v1(try VRM1(data: data))
        } else {
            self = .v0(try VRM0(data: data))
        }
    }

    // MARK: - Common Interface

    /// The underlying BinaryGLTF data
    public var gltf: BinaryGLTF {
        switch self {
        case .v0(let vrm): return vrm.gltf
        case .v1(let vrm): return vrm.gltf
        }
    }

    /// VRM spec version string
    public var specVersion: String {
        switch self {
        case .v0(let vrm): return vrm.version ?? "0.x"
        case .v1(let vrm): return vrm.specVersion
        }
    }

    // MARK: - VRM0 Format interfaces (for current migration period)
    // In the future, these will be replaced with VRM1 native types

    /// Meta information (VRM0 format)
    public var meta: VRM0.Meta {
        switch self {
        case .v0(let vrm): return vrm.meta
        case .v1(let vrm): return VRM0.Meta(vrm1: vrm.meta)
        }
    }

    /// Humanoid bone mapping (VRM0 format)
    public var humanoid: VRM0.Humanoid {
        switch self {
        case .v0(let vrm): return vrm.humanoid
        case .v1(let vrm): return VRM0.Humanoid(vrm1: vrm.humanoid)
        }
    }

    /// Material properties (VRM0 format)
    public var materialProperties: [VRM0.MaterialProperty] {
        switch self {
        case .v0(let vrm): return vrm.materialProperties
        case .v1(let vrm): return VRM0(migratedFrom: vrm).materialProperties
        }
    }

    /// Material property name map (VRM0 format)
    public var materialPropertyNameMap: [String: VRM0.MaterialProperty] {
        switch self {
        case .v0(let vrm): return vrm.materialPropertyNameMap
        case .v1(let vrm): return VRM0(migratedFrom: vrm).materialPropertyNameMap
        }
    }

    /// BlendShape master (VRM0 format)
    public var blendShapeMaster: VRM0.BlendShapeMaster {
        switch self {
        case .v0(let vrm): return vrm.blendShapeMaster
        case .v1(let vrm): return VRM0(migratedFrom: vrm).blendShapeMaster
        }
    }

    /// First person settings (VRM0 format)
    public var firstPerson: VRM0.FirstPerson {
        switch self {
        case .v0(let vrm): return vrm.firstPerson
        case .v1(let vrm): return VRM0(migratedFrom: vrm).firstPerson
        }
    }

    /// Secondary animation / spring bones (VRM0 format)
    public var secondaryAnimation: VRM0.SecondaryAnimation {
        switch self {
        case .v0(let vrm): return vrm.secondaryAnimation
        case .v1(let vrm): return VRM0(migratedFrom: vrm).secondaryAnimation
        }
    }
}
