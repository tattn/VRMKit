import XCTest
import VRMKit
import VRMTestSupport

class VRMAnimationTests: XCTestCase {
    func testParsesTheVRMAExtension() throws {
        let animation = try VRMAnimation(data: VRMASampleFixture.standard())

        XCTAssertEqual(animation.specVersion, "1.0")
        XCTAssertEqual(animation.humanoid?.humanBones["hips"]?.node, 1)
        XCTAssertEqual(animation.humanoid?.humanBones["spine"]?.node, 2)
        // Bone names outside the VRM humanoid parse through untouched.
        XCTAssertEqual(animation.humanoid?.humanBones["tail"]?.node, 7)
        XCTAssertEqual(animation.expressions?.preset?["happy"]?.node, 4)
        XCTAssertEqual(animation.expressions?.custom?["wink"]?.node, 5)
        XCTAssertEqual(animation.lookAt?.node, 6)
        XCTAssertEqual(animation.lookAt?.offsetFromHeadBone, [0, 0.06, 0])
        // The animation itself is plain glTF, parsed as such.
        XCTAssertEqual(animation.document.gltf.animations?.count, 1)
    }

    /// The MIT-licensed three-vrm sample: a real-world `.vrma` in its usual
    /// GLB container, with a full 51-bone humanoid map.
    func testParsesTheThreeVRMSample() throws {
        let animation = try VRMAnimation(withURL: VRMASampleAsset.test.url)

        XCTAssertEqual(animation.specVersion, "1.0")
        XCTAssertEqual(animation.humanoid?.humanBones.count, 51)
        XCTAssertEqual(animation.humanoid?.humanBones["hips"]?.node, 0)
        XCTAssertEqual(animation.expressions?.preset?["happy"]?.node, 51)
        XCTAssertEqual(animation.lookAt?.node, 52)
        XCTAssertEqual(animation.document.gltf.animations?.count, 1)
    }

    /// The bundled CC0 walk cycle, exported by VRM Add-on for Blender: a full
    /// humanoid map with the hips translation locomotion needs.
    func testParsesTheWalkCycle() throws {
        let animation = try VRMAnimation(withURL: VRMASampleAsset.walk.url)

        XCTAssertEqual(animation.specVersion, "1.0")
        XCTAssertEqual(animation.humanoid?.humanBones.count, 54)
        XCTAssertNotNil(animation.humanoid?.humanBones["hips"])
        // The exporter writes the expressions object even with nothing in it.
        XCTAssertEqual(animation.expressions?.preset?.count, 0)
        XCTAssertEqual(animation.expressions?.custom?.count, 0)
        XCTAssertEqual(animation.document.gltf.animations?.count, 1)

        let channels = try XCTUnwrap(animation.document.gltf.animations?.first?.channels)
        XCTAssertEqual(channels.count, 53)
    }

    /// 1.0 is the only released `VRMC_vrm_animation` version; the reference
    /// implementation reads the pre-release 1.0-draft as well, so this does too.
    func testSupportedSpecVersions() {
        XCTAssertTrue(VRMAnimation.supports(specVersion: "1.0"))
        XCTAssertTrue(VRMAnimation.supports(specVersion: "1.0-draft"))
        XCTAssertFalse(VRMAnimation.supports(specVersion: "2.0"))
        XCTAssertFalse(VRMAnimation.supports(specVersion: "1.0-beta"))
    }

    func testADraftSpecVersionStillLoads() throws {
        let animation = try VRMAnimation(data: VRMASampleFixture.standard(specVersion: "1.0-draft"))
        XCTAssertEqual(animation.specVersion, "1.0-draft")
        XCTAssertEqual(animation.humanoid?.humanBones["hips"]?.node, 1)
    }

    func testUnsupportedSpecVersionIsRejected() {
        XCTAssertThrowsError(try VRMAnimation(data: VRMASampleFixture.standard(specVersion: "2.0")))
    }

    /// The spec requires specVersion, but exporters ship `.vrma` without one.
    /// Such a file reads as 1.0 instead of failing to load, as the reference
    /// implementation does; a malformed one still throws.
    func testMissingSpecVersionFallsBackToSupportedVersion() throws {
        let animation = try VRMAnimation(data: VRMASampleFixture.standard(specVersion: nil))
        XCTAssertEqual(animation.specVersion, VRMAnimation.releasedSpecVersion)
        XCTAssertEqual(animation.humanoid?.humanBones["hips"]?.node, 1)

        XCTAssertThrowsError(try VRMAnimation(data: try fixtureWithSpecVersion(1.0)))
    }

    /// The JSON fixture with its `specVersion` replaced by an arbitrary value,
    /// for the malformed cases the fixture's `String?` cannot express.
    private func fixtureWithSpecVersion(_ value: Any) throws -> Data {
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: VRMASampleFixture.standard()) as? [String: Any])
        var extensions = try XCTUnwrap(json["extensions"] as? [String: Any])
        var vrma = try XCTUnwrap(extensions["VRMC_vrm_animation"] as? [String: Any])
        vrma["specVersion"] = value
        extensions["VRMC_vrm_animation"] = vrma
        json["extensions"] = extensions
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testAGLTFWithoutTheExtensionIsRejected() {
        let plain = Data("""
        {"asset": {"version": "2.0"}}
        """.utf8)
        XCTAssertThrowsError(try VRMAnimation(data: plain))
    }
}
