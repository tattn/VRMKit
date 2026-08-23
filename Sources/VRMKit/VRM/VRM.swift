import Foundation

/// VRM data, supporting both VRM0 and VRM1 formats
public enum VRM {
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
        if try document.gltf.rootExtensions().keys.contains(GLTFExtension.vrm1.rawValue) {
            self = .v1(try VRM1(document: document))
        } else {
            self = .v0(try VRM0(document: document))
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

    /// VRM spec version string
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
}
