import Foundation
import simd

public enum VRM: Sendable {
    case v0(VRM0)
    case v1(VRM1)

    /// Parses in-memory VRM data. `rootDirectory` is the base directory for
    /// external resources, which a model written as `.gltf` keeps beside itself.
    public init(data: Data, rootDirectory: URL? = nil) throws {
        try self.init(document: GLTFDocument(data: data, rootDirectory: rootDirectory))
    }

    /// Loads a `.vrm` file. External resources resolve relative to the file's
    /// directory.
    public init(withURL url: URL) throws {
        try self.init(document: try GLTFDocument(withURL: url))
    }

    /// Loads a bundled `.vrm` resource.
    public init(named name: String, in bundle: Bundle = .main) throws {
        try self.init(document: try GLTFDocument(named: name, in: bundle))
    }

    /// Reads whichever version an already-loaded document holds. The document
    /// is handed on rather than parsed again.
    public init(document: GLTFDocument) throws {
        switch try VRMSpecVersion(rootExtensions: try document.gltf.rootExtensions()) {
        case .v0: self = .v0(try VRM0(document: document))
        case .v1: self = .v1(try VRM1(document: document))
        }
    }

    // MARK: - Common Interface

    /// The underlying glTF document, which carries the model's glTF and the
    /// binary resources it is drawn from.
    public var document: GLTFDocument {
        switch self {
        case .v0(let vrm): return vrm.document
        case .v1(let vrm): return vrm.document
        }
    }

    public var specVersion: String {
        switch self {
        case .v0(let vrm): return vrm.version ?? "0.x"
        case .v1(let vrm): return vrm.specVersion
        }
    }

    /// The name the model goes by, whichever version names it.
    public var name: String? {
        switch self {
        case .v0(let vrm): return vrm.meta.title
        case .v1(let vrm): return vrm.meta.name
        }
    }

    /// The way the model faces, in the space its nodes are written in: +Z for
    /// VRM 1.0 and -Z for VRM 0.x. Loading converts no coordinates, so this is
    /// also where a camera looking the model in the face goes.
    public var forwardDirection: SIMD3<Float> {
        switch self {
        case .v0: return SIMD3(0, 0, -1)
        case .v1: return SIMD3(0, 0, 1)
        }
    }
}
