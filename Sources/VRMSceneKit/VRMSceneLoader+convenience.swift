import VRMKit
import Foundation

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension VRMSceneLoader {
    /// Loads a `.vrm` file. External resources resolve relative to the file's
    /// directory.
    public convenience init(withURL url: URL) throws {
        self.init(vrm: try VRM(withURL: url))
    }

    public convenience init(named: String) throws {
        self.init(vrm: try VRM(named: named))
    }

    /// Loads a VRM from in-memory data. `rootDirectory` is the base directory
    /// for external glTF resources.
    public convenience init(withData data: Data, rootDirectory: URL? = nil) throws {
        self.init(vrm: try VRM(data: data, rootDirectory: rootDirectory))
    }
}
