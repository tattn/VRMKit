import Foundation

extension GLTFEditableDocument {
    /// The `VRMC_vrm` and `VRMC_springBone` version an edit writes. Reading also
    /// takes `1.0-beta`, but the two differ in what they hold.
    static let writableSpecVersion = "1.0"

    /// Which VRM the document is, or an error for one this cannot write.
    ///
    /// Stricter than reading only in that a 1.0 spelling this cannot write is refused.
    mutating func vrmSpecVersion() throws -> VRMSpecVersion {
        let version = try VRMSpecVersion(rootExtensions: rootExtensions)
        let name = version.extensionName
        let extensionObject = try rootExtensionObject(name) ??? ._dataInconsistent("\(name) is missing")
        if version == .v1 {
            try requireWritableSpecVersion(of: extensionObject, named: name)
        }
        return version
    }

    /// Refuses an extension declaring a version other than the one written, so
    /// that 1.0 fields are never added to what says it is something else.
    func requireWritableSpecVersion(of extensionObject: JSONObject, named name: String) throws {
        let specVersion = try extensionObject.string("specVersion")
            ??? ._dataInconsistent("\(name).specVersion is missing or not a string")
        guard specVersion == Self.writableSpecVersion else {
            throw VRMError._notSupported("editing a \(name) of specVersion \(specVersion)")
        }
    }
}
