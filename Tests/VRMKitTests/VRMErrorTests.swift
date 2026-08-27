import Foundation
import Testing
import VRMTestSupport
@testable import VRMKit

/// What a failed load tells the caller.
@Suite
struct VRMErrorTests {
    /// The kind is what a caller branches on; the message is what it shows.
    @Test
    func testAFailedLoadCarriesBothAKindAndAReadableMessage() throws {
        let truncated = VRMSampleAsset.aliciaSolid.data.prefix(40)

        let error = try #require(throws: VRMError.self) { try VRM(data: Data(truncated)) }

        #expect(error.kind == .dataInconsistent)
        #expect(error.message.contains("GLB header length"))
    }

    /// The message is what a person reads, so where in VRMKit the error was raised stays
    /// out of it and rides on the error for a bug report instead.
    @Test
    func testWhereAnErrorWasRaisedStaysOutOfItsMessage() {
        let error = VRMError._dataInconsistent("the buffer view overruns its buffer")

        #expect(error.message == "the buffer view overruns its buffer")
        #expect(error.localizedDescription == "the buffer view overruns its buffer")
        #expect(error.origin?.contains("VRMErrorTests.swift") == true)
        #expect(error.debugDescription.contains("the buffer view overruns its buffer"))
        #expect(error.debugDescription.contains("VRMErrorTests.swift"))
    }

    /// A model naming no thumbnail says so as itself, not as a mangled load failure.
    @Test
    func testAModelWithNoThumbnailSaysSo() throws {
        let stripped = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var extensions = json.object("extensions") ?? [:]
            var vrm = extensions.object("VRM") ?? [:]
            var meta = vrm.object("meta") ?? [:]
            meta.removeValue(forKey: "texture")
            vrm["meta"] = .object(meta)
            extensions["VRM"] = .object(vrm)
            json["extensions"] = .object(extensions)
        }
        let vrm = try VRM(data: stripped)

        let error = try #require(throws: VRMError.self) { try vrm.thumbnail }
        #expect(error.kind == .thumbnailNotFound)
    }
}
