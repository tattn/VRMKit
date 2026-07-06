#if canImport(RealityKit)
import Foundation
import VRMKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension VRMEntityLoader {
    public convenience init(withURL url: URL, rootDirectory: URL? = nil, isMToonEnabled: Bool = true) throws {
        let vrm = try VRMLoader().load(withURL: url)
        self.init(vrm: vrm, rootDirectory: rootDirectory, isMToonEnabled: isMToonEnabled)
    }

    public convenience init(named: String, rootDirectory: URL? = nil, isMToonEnabled: Bool = true) throws {
        let vrm = try VRMLoader().load(named: named)
        self.init(vrm: vrm, rootDirectory: rootDirectory, isMToonEnabled: isMToonEnabled)
    }

    public convenience init(withData data: Data, rootDirectory: URL? = nil, isMToonEnabled: Bool = true) throws {
        let vrm = try VRMLoader().load(withData: data)
        self.init(vrm: vrm, rootDirectory: rootDirectory, isMToonEnabled: isMToonEnabled)
    }
}
#endif
