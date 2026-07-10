#if canImport(RealityKit)
import Foundation
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension VRMEntityLoader {
    /// Loads a VRM from a file URL.
    ///
    /// - Parameters:
    ///   - url: VRM file location.
    ///   - rootDirectory: Optional base directory for external glTF resources.
    ///   - isMToonEnabled: When `false`, MToon is fully disabled and Unlit / PBR fallbacks are used.
    ///   - isOutlineEnabled: Controls creation of MToon outline entities.
    ///   - isShadowCastingEnabled: Controls model participation in RealityKit shadow passes.
    public convenience init(withURL url: URL,
                            rootDirectory: URL? = nil,
                            isMToonEnabled: Bool = true,
                            isOutlineEnabled: Bool = true,
                            isShadowCastingEnabled: Bool = true) throws {
        let vrm = try VRMLoader().load(withURL: url)
        self.init(vrm: vrm,
                  rootDirectory: rootDirectory,
                  isMToonEnabled: isMToonEnabled,
                  isOutlineEnabled: isOutlineEnabled,
                  isShadowCastingEnabled: isShadowCastingEnabled)
    }

    /// Loads a bundled VRM resource.
    public convenience init(named: String,
                            rootDirectory: URL? = nil,
                            isMToonEnabled: Bool = true,
                            isOutlineEnabled: Bool = true,
                            isShadowCastingEnabled: Bool = true) throws {
        let vrm = try VRMLoader().load(named: named)
        self.init(vrm: vrm,
                  rootDirectory: rootDirectory,
                  isMToonEnabled: isMToonEnabled,
                  isOutlineEnabled: isOutlineEnabled,
                  isShadowCastingEnabled: isShadowCastingEnabled)
    }

    /// Loads a VRM from in-memory data.
    public convenience init(withData data: Data,
                            rootDirectory: URL? = nil,
                            isMToonEnabled: Bool = true,
                            isOutlineEnabled: Bool = true,
                            isShadowCastingEnabled: Bool = true) throws {
        let vrm = try VRMLoader().load(withData: data)
        self.init(vrm: vrm,
                  rootDirectory: rootDirectory,
                  isMToonEnabled: isMToonEnabled,
                  isOutlineEnabled: isOutlineEnabled,
                  isShadowCastingEnabled: isShadowCastingEnabled)
    }
}
#endif
