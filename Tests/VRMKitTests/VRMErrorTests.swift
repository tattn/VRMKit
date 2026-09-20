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

    /// However the bytes are cut short, the loader reports a typed error or, rarely,
    /// succeeds on a prefix that still happens to be well formed. It never traps, and
    /// its message never carries the raw bytes it failed to make sense of.
    @Test
    func testATruncatedFileAtEveryLengthNeverTrapsOrLeaksRawBytes() {
        let whole = VRMSampleAsset.aliciaSolid.data
        // A fixed number of evenly spaced samples, so this stays fast regardless of how
        // large the fixture is, while still crossing every section of the file at least once.
        let sampleCount = 60
        let stride = max(1, whole.count / sampleCount)
        for length in Swift.stride(from: 0, to: whole.count, by: stride) {
            let prefix = Data(whole.prefix(length))
            do {
                _ = try VRM(data: prefix)
            } catch let error as VRMError {
                #expect(!error.message.contains(prefix.base64EncodedString().prefix(32)),
                         "message leaked the raw bytes at length \(length)")
            } catch {
                Issue.record("length \(length) threw \(type(of: error)) instead of VRMError")
            }
        }
    }

    /// Every error a caller can branch on names one of the declared kinds, so a switch
    /// over `VRMError.Kind` need not fall back to a raw, undiagnosable case.
    @Test
    func testMalformedInputsEachCarryOneOfTheDeclaredKinds() throws {
        #expect(throws: VRMError.self) { try VRM(data: Data()) }
        #expect(throws: VRMError.self) {
            try VRM(data: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]))
        }

        let notAnObject = try VRMSampleAsset.aliciaSolid.rewritingJSON { $0["extensions"] = .null }
        #expect(throws: VRMError.self) { try VRM(data: notAnObject) }
    }
}
