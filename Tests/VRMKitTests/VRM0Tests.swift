import Testing
import VRMKit
import VRMTestSupport

@Suite
struct VRM0Tests {

    let vrm: VRM0

    init() throws {
        vrm = try VRM0(data: VRMSampleAsset.aliciaSolid.data)
    }

    @Test
    func testMeta() {
        #expect(vrm.meta.title == "Alicia Solid")
        #expect(vrm.meta.author == "DWANGO Co., Ltd.")
        #expect(vrm.meta.contactInformation == "http://3d.nicovideo.jp/alicia/")
        #expect(vrm.meta.reference == "")
        #expect(vrm.meta.texture == 6)
        #expect(vrm.meta.version == "1.0.0")

        #expect(vrm.meta.allowedUserName == "Everyone")
        #expect(vrm.meta.violentUsage == "Disallow")
        #expect(vrm.meta.sexualUsage == "Disallow")
        #expect(vrm.meta.commercialUsage == "Allow")
        #expect(vrm.meta.otherPermissionUrl == "http://3d.nicovideo.jp/alicia/rule.html")

        #expect(vrm.meta.licenseName == "Other")
        #expect(vrm.meta.otherLicenseUrl == "http://3d.nicovideo.jp/alicia/rule.html")
    }

    @Test
    func testMaterialProperties() {
        let target = vrm.materialProperties[3]
        #expect(target.name == "Alicia_face")
        #expect(target.shader == "VRM/UnlitTexture")
        #expect(target.renderQueue == 2000)
        #expect(target.floatProperties.isEmpty)
        #expect(target.keywordMap == ["_ALPHAPREMULTIPLY_ON": true])
        #expect(target.tagMap == ["RenderType": "Opaque"])
        #expect(target.textureProperties == ["_MainTex": 3])
        #expect(target.vectorProperties.isEmpty)
    }

    @Test
    func testHumanoid() {
        #expect(vrm.humanoid.armStretch == 0.05)
        #expect(vrm.humanoid.feetSpacing == 0)
        #expect(vrm.humanoid.hasTranslationDoF == false)
        #expect(vrm.humanoid.legStretch == 0.05)
        #expect(vrm.humanoid.lowerArmTwist == 0.5)
        #expect(vrm.humanoid.lowerLegTwist == 0.5)
        #expect(vrm.humanoid.upperArmTwist == 0.5)
        #expect(vrm.humanoid.upperLegTwist == 0.5)
        #expect(vrm.humanoid.humanBones[0].bone == "hips")
        #expect(vrm.humanoid.humanBones[0].node == 3)
        #expect(vrm.humanoid.humanBones[0].useDefaultValues == true)
    }

    @Test
    func testBlendShapeMaster() {
        let target = vrm.blendShapeMaster.blendShapeGroups[1]
        #expect(target.binds[0].index == 0)
        #expect(target.binds[0].mesh == 3)
        #expect(target.binds[0].weight == 100)
        #expect(target.materialValues.isEmpty)
        #expect(target.name == "A")
        #expect(target.presetName == "a")
        #expect(target.isBinary == false)
    }

    @Test
    func testFirstPerson() {
        #expect(vrm.firstPerson?.firstPersonBone == 36)
        #expect(vrm.firstPerson?.firstPersonBoneOffset.x == 0)
        #expect(vrm.firstPerson?.firstPersonBoneOffset.y == 0.06)
        #expect(vrm.firstPerson?.firstPersonBoneOffset.z == 0)
        #expect(vrm.firstPerson?.meshAnnotations[0].firstPersonFlag == "Auto")
        #expect(vrm.firstPerson?.meshAnnotations[0].mesh == 0)
    }

    /// The four curves the gaze passes through, which VRM 1.0 states as range maps.
    @Test
    func testFirstPersonLookAtCurves() throws {
        #expect(vrm.firstPerson?.lookAtTypeName == .bone)
        let inner = try #require(vrm.firstPerson?.lookAtHorizontalInner)
        #expect(inner.xRange == 30)
        #expect(inner.yRange == 10)
        #expect(inner.curve == [0, 0, 0, 1, 1, 1, 1, 0])
        #expect(vrm.firstPerson?.lookAtHorizontalOuter?.yRange == 10)
        #expect(vrm.firstPerson?.lookAtVerticalDown?.yRange == 10)
        // The one map this model tunes away from the rest.
        #expect(vrm.firstPerson?.lookAtVerticalUp?.yRange == 8)
    }

    @Test
    func testSecondaryAnimationBoneGroups() {
        let target = vrm.secondaryAnimation.boneGroups[0]
        #expect(target.bones == [41, 49, 57, 59, 61])
        #expect(target.center == -1)
        #expect(target.colliderGroups == [2, 1, 0, 3, 5, 4, 6])
        #expect(target.comment == "")
        #expect(target.dragForce == 0.4)
        #expect(target.gravityDir.x == 0.0)
        #expect(target.gravityDir.y == -1.0)
        #expect(target.gravityDir.z == 0.0)
        #expect(target.gravityPower == 0.0)
        #expect(target.hitRadius == 0.01)
        #expect(target.stiffness == 0.65)
    }

    @Test
    func testSecondaryAnimationColliderGroups() {
        let target = vrm.secondaryAnimation.colliderGroups[0]
        #expect(target.node == 34)
        #expect(target.colliders[0].offset.x == 0.0)
        #expect(target.colliders[0].offset.y == 0.05)
        #expect(target.colliders[0].offset.z == 0.0)
        #expect(target.colliders[0].radius == 0.09)
    }

    @Test
    func testVRMVersionDetection() throws {
        guard case .v0(let vrm0) = try VRM(data: VRMSampleAsset.aliciaSolid.data) else {
            Issue.record("Expected VRM0")
            return
        }
        #expect(vrm0.meta.title == "Alicia Solid")
    }
}
