import Foundation

/// Loads plain glTF assets into a ``GLTFDocument``: GLB containers, and JSON
/// `.gltf` files with external or data-URI resources.
public final class GLTFLoader {
    public init() {}

    /// Loads a bundled glTF resource.
    public func load(named name: String) throws -> GLTFDocument {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
            throw URLError(.fileDoesNotExist)
        }
        return try load(withURL: url)
    }

    /// Loads a `.glb` / `.gltf` file. External resources resolve relative to
    /// the file's directory.
    public func load(withURL url: URL) throws -> GLTFDocument {
        let data = try Data(contentsOf: url)
        return try load(withData: data, rootDirectory: url.deletingLastPathComponent())
    }

    /// Loads in-memory glTF data, sniffing the GLB magic to pick the container
    /// format. `rootDirectory` is the base directory for external resources.
    public func load(withData data: Data, rootDirectory: URL? = nil) throws -> GLTFDocument {
        if BinaryGLTF.isGLB(data) {
            return GLTFDocument(binary: try BinaryGLTF(data: data), rootDirectory: rootDirectory)
        }
        let gltf = try JSONDecoder().decode(GLTF.self, from: data)
        try gltf.validateSupportedAssetVersion()
        return GLTFDocument(gltf: gltf, rootDirectory: rootDirectory)
    }
}
