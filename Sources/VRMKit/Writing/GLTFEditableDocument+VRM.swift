import Foundation

extension GLTFEditableDocument {
    /// The `VRMC_vrm` and `VRMC_springBone` version an edit writes. Reading also
    /// takes `1.0-beta`, but the two differ in what they hold.
    static let writableSpecVersion = "1.0"

    /// Which VRM the document is, or an error for one this cannot write.
    ///
    /// Stricter than reading: a document naming a version this cannot write, or
    /// naming two versions at once, is refused rather than written on a guess.
    func vrmSpecVersion() throws -> VRMSpecVersion {
        let vrm0 = try rootExtensionObject(GLTFExtension.vrm0.rawValue)
        let vrm1 = try rootExtensionObject(GLTFExtension.vrm1.rawValue)
        guard vrm0 == nil || vrm1 == nil else {
            throw VRMError._dataInconsistent(
                "the document carries both \(GLTFExtension.vrm0.rawValue) and \(GLTFExtension.vrm1.rawValue), "
                + "so which version an edit is written in is not for this to guess"
            )
        }
        if let vrm1 {
            try requireWritableSpecVersion(of: vrm1, named: GLTFExtension.vrm1.rawValue)
            return .v1
        }
        guard vrm0 != nil else {
            throw VRMError._notSupported("the document carries no VRM extension, so there is nothing to edit")
        }
        return .v0
    }

    /// Refuses an extension declaring a version other than the one written, so
    /// that 1.0 fields are never added to what says it is something else.
    func requireWritableSpecVersion(of extensionObject: JSONObject, named name: String) throws {
        let specVersion = try extensionObject["specVersion"] as? String
            ??? ._dataInconsistent("\(name).specVersion is missing or not a string")
        guard specVersion == Self.writableSpecVersion else {
            throw VRMError._notSupported("editing a \(name) of specVersion \(specVersion)")
        }
    }
}
