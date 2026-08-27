import Foundation
import Testing
import VRMKit
import VRMTestSupport

@Suite
struct VRMAnimationTests {
    @Test
    func testParsesTheVRMAExtension() throws {
        let animation = try VRMAnimation(data: VRMASampleFixture.standard())

        #expect(animation.specVersion == "1.0")
        #expect(animation.humanoid?.humanBones["hips"]?.node == 1)
        #expect(animation.humanoid?.humanBones["spine"]?.node == 2)
        // Bone names outside the VRM humanoid parse through untouched.
        #expect(animation.humanoid?.humanBones["tail"]?.node == 7)
        #expect(animation.expressions?.preset?["happy"]?.node == 4)
        #expect(animation.expressions?.custom?["wink"]?.node == 5)
        #expect(animation.lookAt?.node == 6)
        #expect(animation.lookAt?.offsetFromHeadBone == [0, 0.06, 0])
        // The animation itself is plain glTF, parsed as such.
        #expect(animation.document.gltf.animations?.count == 1)
    }

    /// The MIT-licensed three-vrm sample: a real-world `.vrma` in its usual
    /// GLB container, with a full 51-bone humanoid map.
    @Test
    func testParsesTheThreeVRMSample() throws {
        let animation = try VRMAnimation(withURL: VRMASampleAsset.test.url)

        #expect(animation.specVersion == "1.0")
        #expect(animation.humanoid?.humanBones.count == 51)
        #expect(animation.humanoid?.humanBones["hips"]?.node == 0)
        #expect(animation.expressions?.preset?["happy"]?.node == 51)
        #expect(animation.lookAt?.node == 52)
        #expect(animation.document.gltf.animations?.count == 1)
    }

    /// The bundled CC0 walk cycle, exported by VRM Add-on for Blender: a full
    /// humanoid map with the hips translation locomotion needs.
    @Test
    func testParsesTheWalkCycle() throws {
        let animation = try VRMAnimation(withURL: VRMASampleAsset.walk.url)

        #expect(animation.specVersion == "1.0")
        #expect(animation.humanoid?.humanBones.count == 54)
        #expect(animation.humanoid?.humanBones["hips"] != nil)
        // The exporter writes the expressions object even with nothing in it.
        #expect(animation.expressions?.preset?.count == 0)
        #expect(animation.expressions?.custom?.count == 0)
        #expect(animation.document.gltf.animations?.count == 1)

        let channels = try #require(animation.document.gltf.animations?.first?.channels)
        #expect(channels.count == 53)
    }

    /// 1.0 is the only released `VRMC_vrm_animation` version; the reference
    /// implementation reads the pre-release 1.0-draft as well, so this does too.
    @Test
    func testSupportedSpecVersions() {
        #expect(VRMAnimation.supports(specVersion: "1.0"))
        #expect(VRMAnimation.supports(specVersion: "1.0-draft"))
        #expect(!(VRMAnimation.supports(specVersion: "2.0")))
        #expect(!(VRMAnimation.supports(specVersion: "1.0-beta")))
    }

    @Test
    func testADraftSpecVersionStillLoads() throws {
        let animation = try VRMAnimation(data: VRMASampleFixture.standard(specVersion: "1.0-draft"))
        #expect(animation.specVersion == "1.0-draft")
        #expect(animation.humanoid?.humanBones["hips"]?.node == 1)
    }

    @Test
    func testUnsupportedSpecVersionIsRejected() {
        #expect(throws: (any Error).self) { try VRMAnimation(data: VRMASampleFixture.standard(specVersion: "2.0")) }
    }

    /// The spec requires specVersion, but exporters ship `.vrma` without one.
    /// Such a file reads as 1.0 instead of failing to load, as the reference
    /// implementation does; a malformed one still throws.
    @Test
    func testMissingSpecVersionFallsBackToSupportedVersion() throws {
        let animation = try VRMAnimation(data: VRMASampleFixture.standard(specVersion: nil))
        #expect(animation.specVersion == VRMAnimation.releasedSpecVersion)
        #expect(animation.humanoid?.humanBones["hips"]?.node == 1)

        #expect(throws: (any Error).self) { try VRMAnimation(data: try fixtureWithSpecVersion(1.0)) }
    }

    /// The JSON fixture with its `specVersion` replaced by an arbitrary value,
    /// for the malformed cases the fixture's `String?` cannot express.
    private func fixtureWithSpecVersion(_ value: JSONValue) throws -> Data {
        var json = try #require(try JSONValue(parsing: VRMASampleFixture.standard()).objectValue)
        var extensions = try #require(json.object("extensions"))
        var vrma = try #require(extensions.object("VRMC_vrm_animation"))
        vrma["specVersion"] = value
        extensions["VRMC_vrm_animation"] = .object(vrma)
        json["extensions"] = .object(extensions)
        return try JSONValue.object(json).serialized()
    }

    @Test
    func testAGLTFWithoutTheExtensionIsRejected() {
        let plain = Data("""
        {"asset": {"version": "2.0"}}
        """.utf8)
        #expect(throws: (any Error).self) { try VRMAnimation(data: plain) }
    }
}
