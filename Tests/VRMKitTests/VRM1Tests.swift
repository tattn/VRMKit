import Foundation
import simd
import Testing
import VRMKit
import VRMTestSupport

@Suite
struct VRM1Tests {
    
    let vrm: VRM1

    init() throws {
        vrm = try VRM1(data: VRMSampleAsset.seedSan.data)
    }
    
    @Test
    func testSpecVersion() {
        #expect(vrm.specVersion == "1.0")
    }

    /// A missing or mistyped specVersion surfaces as a thrown error rather than
    /// trapping in the initializer.
    @Test
    func testMalformedSpecVersionThrowsInsteadOfCrashing() throws {
        #expect(throws: (any Error).self) { try VRM1(data: try VRMSampleAsset.seedSan.withVRMCSpecVersion(nil)) }
        #expect(throws: (any Error).self) { try VRM1(data: try VRMSampleAsset.seedSan.withVRMCSpecVersion(1.0)) }
        #expect(throws: (any Error).self) { try VRM1(data: try VRMSampleAsset.seedSan.withVRMCSpecVersion(["1.0"])) }
    }

    @Test
    func testUnsupportedSpecVersionIsRejected() throws {
        #expect(VRM1.supports(specVersion: "1.0"))
        #expect(VRM1.supports(specVersion: "1.0-beta"))
        #expect(!(VRM1.supports(specVersion: "2.0")))
        #expect(!(VRM1.supports(specVersion: "1.0-draft")))

        #expect(throws: Never.self) { try VRM1(data: try VRMSampleAsset.seedSan.withVRMCSpecVersion("1.0-beta")) }
        #expect(throws: (any Error).self) { try VRM1(data: try VRMSampleAsset.seedSan.withVRMCSpecVersion("2.0")) }
    }

    /// `VRMC_springBone` is versioned on its own, and springs of a version this cannot
    /// read would be simulated as if they said something else.
    @Test
    func testAnUnsupportedSpringBoneSpecVersionStillLoads() throws {
        #expect(VRM1.SpringBone.supports(specVersion: "1.0"))
        #expect(VRM1.SpringBone.supports(specVersion: "1.0-beta"))
        #expect(!VRM1.SpringBone.supports(specVersion: "2.0"))

        let raised = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var extensions = json.object("extensions") ?? [:]
            var springBone = try #require(extensions.object("VRMC_springBone"))
            springBone["specVersion"] = "2.0"
            extensions["VRMC_springBone"] = .object(springBone)
            json["extensions"] = .object(extensions)
        }
        // Decoded leniently: the version travels with the data, and building the rig is
        // what leaves an unsupported one out.
        let vrm = try VRM1(data: raised)
        #expect(vrm.springBone?.specVersion == "2.0")
        #expect(!VRM1.SpringBone.supports(specVersion: vrm.springBone?.specVersion))
    }

    
    @Test
    func testMeta() {
        #expect(vrm.meta.name == "Seed-san")
        #expect(vrm.meta.version == "1")
        #expect(vrm.meta.authors == ["VirtualCast, Inc."])
        #expect(vrm.meta.copyrightInformation == "VirtualCast, Inc.")
        #expect(vrm.meta.contactInformation == nil)
        #expect(vrm.meta.references == nil)
        #expect(vrm.meta.thirdPartyLicenses == nil)
        #expect(vrm.meta.thumbnailImage == 14)
        #expect(vrm.meta.licenseUrl == "https://vrm.dev/licenses/1.0/")
        #expect(vrm.meta.avatarPermission == .everyone)
        #expect(vrm.meta.allowExcessivelyViolentUsage == true)
        #expect(vrm.meta.allowExcessivelySexualUsage == true)
        #expect(vrm.meta.commercialUsage == .corporation)
        #expect(vrm.meta.allowPoliticalOrReligiousUsage == true)
        #expect(vrm.meta.allowAntisocialOrHateUsage == true)
        #expect(vrm.meta.creditNotation == .required)
        #expect(vrm.meta.allowRedistribution == true)
        #expect(vrm.meta.modification == .allowModificationRedistribution)
        #expect(vrm.meta.otherLicenseUrl == nil)
    }
    
    @Test
    func testFirstPerson() {
        #expect(vrm.firstPerson?.meshAnnotations.count == 5)
        #expect(vrm.firstPerson?.meshAnnotations[0].type == .thirdPersonOnly)
        #expect(vrm.firstPerson?.meshAnnotations[0].node == 0)
        #expect(vrm.firstPerson?.meshAnnotations[1].type == .thirdPersonOnly)
        #expect(vrm.firstPerson?.meshAnnotations[1].node == 1)
        #expect(vrm.firstPerson?.meshAnnotations[2].type == .thirdPersonOnly)
        #expect(vrm.firstPerson?.meshAnnotations[2].node == 2)
        #expect(vrm.firstPerson?.meshAnnotations[3].type == .both)
        #expect(vrm.firstPerson?.meshAnnotations[3].node == 144)
        #expect(vrm.firstPerson?.meshAnnotations[4].type == .both)
        #expect(vrm.firstPerson?.meshAnnotations[4].node == 145)
    }
    
    @Test
    func testLookAt() {
        #expect(vrm.lookAt?.offsetFromHeadBone.x == 0)
        #expect(vrm.lookAt?.offsetFromHeadBone.y == 0.07764859)
        #expect(vrm.lookAt?.offsetFromHeadBone.z == 0.100730225)
        #expect(vrm.lookAt?.type == .expression)
        #expect(vrm.lookAt?.rangeMapHorizontalInner?.inputMaxValue == 90)
        #expect(vrm.lookAt?.rangeMapHorizontalInner?.outputScale == 1)
        #expect(vrm.lookAt?.rangeMapHorizontalOuter?.inputMaxValue == 90)
        #expect(vrm.lookAt?.rangeMapHorizontalOuter?.outputScale == 1)
        #expect(vrm.lookAt?.rangeMapVerticalDown?.inputMaxValue == 90)
        #expect(vrm.lookAt?.rangeMapVerticalDown?.outputScale == 1)
        #expect(vrm.lookAt?.rangeMapVerticalUp?.inputMaxValue == 90)
        #expect(vrm.lookAt?.rangeMapVerticalUp?.outputScale == 1)
    }
    
    @Test
    func testHumanoid() {
        #expect(vrm.humanoid.humanBones[.hips]?.node == 3)
        #expect(vrm.humanoid.humanBones[.spine]?.node == 4)
        #expect(vrm.humanoid.humanBones[.chest]?.node == 5)
        #expect(vrm.humanoid.humanBones[.upperChest]?.node == nil)
        #expect(vrm.humanoid.humanBones[.neck]?.node == 44)
        #expect(vrm.humanoid.humanBones[.head]?.node == 45)
        #expect(vrm.humanoid.humanBones[.leftEye]?.node == nil)
        #expect(vrm.humanoid.humanBones[.rightEye]?.node == nil)
        #expect(vrm.humanoid.humanBones[.jaw]?.node == nil)
        #expect(vrm.humanoid.humanBones[.leftUpperLeg]?.node == 130)
        #expect(vrm.humanoid.humanBones[.leftLowerLeg]?.node == 131)
        #expect(vrm.humanoid.humanBones[.leftFoot]?.node == 132)
        #expect(vrm.humanoid.humanBones[.leftToes]?.node == 134)
        #expect(vrm.humanoid.humanBones[.rightUpperLeg]?.node == 137)
        #expect(vrm.humanoid.humanBones[.rightLowerLeg]?.node == 138)
        #expect(vrm.humanoid.humanBones[.rightFoot]?.node == 139)
        #expect(vrm.humanoid.humanBones[.rightToes]?.node == 141)
        #expect(vrm.humanoid.humanBones[.leftShoulder]?.node == 82)
        #expect(vrm.humanoid.humanBones[.leftUpperArm]?.node == 83)
        #expect(vrm.humanoid.humanBones[.leftLowerArm]?.node == 84)
        #expect(vrm.humanoid.humanBones[.leftHand]?.node == 86)
        #expect(vrm.humanoid.humanBones[.rightShoulder]?.node == 106)
        #expect(vrm.humanoid.humanBones[.rightUpperArm]?.node == 107)
        #expect(vrm.humanoid.humanBones[.rightLowerArm]?.node == 108)
        #expect(vrm.humanoid.humanBones[.rightHand]?.node == 110)
        #expect(vrm.humanoid.humanBones[.leftThumbMetacarpal]?.node == 91)
        #expect(vrm.humanoid.humanBones[.leftThumbProximal]?.node == 92)
        #expect(vrm.humanoid.humanBones[.leftThumbDistal]?.node == 93)
        #expect(vrm.humanoid.humanBones[.leftIndexProximal]?.node == 88)
        #expect(vrm.humanoid.humanBones[.leftIndexIntermediate]?.node == 89)
        #expect(vrm.humanoid.humanBones[.leftIndexDistal]?.node == 90)
        #expect(vrm.humanoid.humanBones[.leftMiddleProximal]?.node == 95)
        #expect(vrm.humanoid.humanBones[.leftMiddleIntermediate]?.node == 96)
        #expect(vrm.humanoid.humanBones[.leftMiddleDistal]?.node == 97)
        #expect(vrm.humanoid.humanBones[.leftRingProximal]?.node == 99)
        #expect(vrm.humanoid.humanBones[.leftRingIntermediate]?.node == 100)
        #expect(vrm.humanoid.humanBones[.leftRingDistal]?.node == 101)
        #expect(vrm.humanoid.humanBones[.leftLittleProximal]?.node == 103)
        #expect(vrm.humanoid.humanBones[.leftLittleIntermediate]?.node == 104)
        #expect(vrm.humanoid.humanBones[.leftLittleDistal]?.node == 105)
        #expect(vrm.humanoid.humanBones[.rightThumbMetacarpal]?.node == 115)
        #expect(vrm.humanoid.humanBones[.rightThumbProximal]?.node == 116)
        #expect(vrm.humanoid.humanBones[.rightThumbDistal]?.node == 117)
        #expect(vrm.humanoid.humanBones[.rightIndexProximal]?.node == 112)
        #expect(vrm.humanoid.humanBones[.rightIndexIntermediate]?.node == 113)
        #expect(vrm.humanoid.humanBones[.rightIndexDistal]?.node == 114)
        #expect(vrm.humanoid.humanBones[.rightMiddleProximal]?.node == 119)
        #expect(vrm.humanoid.humanBones[.rightMiddleIntermediate]?.node == 120)
        #expect(vrm.humanoid.humanBones[.rightMiddleDistal]?.node == 121)
        #expect(vrm.humanoid.humanBones[.rightRingProximal]?.node == 123)
        #expect(vrm.humanoid.humanBones[.rightRingIntermediate]?.node == 124)
        #expect(vrm.humanoid.humanBones[.rightRingDistal]?.node == 125)
        #expect(vrm.humanoid.humanBones[.rightLittleProximal]?.node == 127)
        #expect(vrm.humanoid.humanBones[.rightLittleIntermediate]?.node == 128)
        #expect(vrm.humanoid.humanBones[.rightLittleDistal]?.node == 129)
    }

    @Test
    func testExpressionsPresetAllowsMissingEntries() throws {
        let json = """
        {
          "preset": {
            "happy": {
              "morphTargetBinds": [
                { "node": 1, "index": 2, "weight": 0.5 }
              ]
            }
          }
        }
        """.data(using: .utf8)!

        let expressions = try JSONDecoder().decode(VRM1.Expressions.self, from: json)

        #expect(expressions.preset?.happy?.morphTargetBinds?.first?.node == 1)
        #expect(expressions.preset?.angry == nil)
    }

    @Test
    func testExpressionsAllowsCustomOnly() throws {
        let json = """
        {
          "custom": {
            "smile": {
              "morphTargetBinds": [
                { "node": 1, "index": 2, "weight": 1.0 }
              ]
            }
          }
        }
        """.data(using: .utf8)!

        let expressions = try JSONDecoder().decode(VRM1.Expressions.self, from: json)

        #expect(expressions.preset == nil)
        #expect(expressions.custom != nil)
    }

    @Test
    func testExpressions() {
        assertEmotionExpressions()
        assertSpeechAndEyeExpressions()
    }

    /// Every emotion preset of the fixture is bound the same way: one morph target on
    /// node 2, one texture transform on material 11 scaled 1:1, and binary blending.
    /// Only the target, the offset and the overrides differ.
    private func assertEmotionExpressions() {
        assertEmotionExpression(vrm.expressions?.preset?.happy,
                                morphTargetIndex: 33,
                                textureOffset: [0.25, 0],
                                overrideBlink: .blend,
                                overrideLookAt: .none,
                                overrideMouth: .none)
        assertEmotionExpression(vrm.expressions?.preset?.angry,
                                morphTargetIndex: 34,
                                textureOffset: [0.5, 0],
                                overrideBlink: .none,
                                overrideLookAt: .none,
                                overrideMouth: .none)
        assertEmotionExpression(vrm.expressions?.preset?.sad,
                                morphTargetIndex: 35,
                                textureOffset: [0.75, 0],
                                overrideBlink: .none,
                                overrideLookAt: .none,
                                overrideMouth: .none)
        assertEmotionExpression(vrm.expressions?.preset?.relaxed,
                                morphTargetIndex: 36,
                                textureOffset: [0.5, 0.25],
                                overrideBlink: .block,
                                overrideLookAt: .block,
                                overrideMouth: .none)
        assertEmotionExpression(vrm.expressions?.preset?.surprised,
                                morphTargetIndex: 38,
                                textureOffset: [0, 0.25],
                                overrideBlink: .none,
                                overrideLookAt: .none,
                                overrideMouth: .none)
    }

    private typealias ExpressionOverride = VRM1.Expressions.Expression.ExpressionOverrideType

    private func assertEmotionExpression(_ expression: VRM1.Expressions.Expression?,
                                         morphTargetIndex: Int,
                                         textureOffset: SIMD2<Float>,
                                         overrideBlink: ExpressionOverride,
                                         overrideLookAt: ExpressionOverride,
                                         overrideMouth: ExpressionOverride,
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(expression?.morphTargetBinds?.count == 1, sourceLocation: sourceLocation)
        #expect(expression?.morphTargetBinds?[0].node == 2, sourceLocation: sourceLocation)
        #expect(expression?.morphTargetBinds?[0].index == morphTargetIndex, sourceLocation: sourceLocation)
        #expect(expression?.morphTargetBinds?[0].weight == 1, sourceLocation: sourceLocation)
        #expect(expression?.materialColorBinds?.count == nil, sourceLocation: sourceLocation)
        #expect(expression?.textureTransformBinds?.count == 1, sourceLocation: sourceLocation)
        #expect(expression?.textureTransformBinds?[0].material == 11, sourceLocation: sourceLocation)
        #expect(expression?.textureTransformBinds?[0].offset == textureOffset, sourceLocation: sourceLocation)
        #expect(expression?.textureTransformBinds?[0].scale == [1, 1], sourceLocation: sourceLocation)
        #expect(expression?.isBinary == true, sourceLocation: sourceLocation)
        #expect(expression?.overrideBlink == overrideBlink, sourceLocation: sourceLocation)
        #expect(expression?.overrideLookAt == overrideLookAt, sourceLocation: sourceLocation)
        #expect(expression?.overrideMouth == overrideMouth, sourceLocation: sourceLocation)
    }

    /// The speech and eye presets of the fixture bind morph targets on node 2 at full
    /// weight and nothing else: no material colour, texture transform, binary blending
    /// or overrides.
    private func assertSpeechAndEyeExpressions() {
        assertPlainExpression(vrm.expressions?.preset?.aa, morphTargetIndices: [25])
        assertPlainExpression(vrm.expressions?.preset?.ih, morphTargetIndices: [26])
        assertPlainExpression(vrm.expressions?.preset?.ou, morphTargetIndices: [27])
        assertPlainExpression(vrm.expressions?.preset?.ee, morphTargetIndices: [28])
        assertPlainExpression(vrm.expressions?.preset?.oh, morphTargetIndices: [29])
        assertPlainExpression(vrm.expressions?.preset?.blink, morphTargetIndices: [1, 2])
        assertPlainExpression(vrm.expressions?.preset?.blinkLeft, morphTargetIndices: [1])
        assertPlainExpression(vrm.expressions?.preset?.blinkRight, morphTargetIndices: [2])
        assertPlainExpression(vrm.expressions?.preset?.lookUp, morphTargetIndices: [39])
        assertPlainExpression(vrm.expressions?.preset?.lookDown, morphTargetIndices: [40])
        assertPlainExpression(vrm.expressions?.preset?.lookLeft, morphTargetIndices: [41])
        assertPlainExpression(vrm.expressions?.preset?.lookRight, morphTargetIndices: [42])
        assertPlainExpression(vrm.expressions?.preset?.neutral, morphTargetIndices: nil)
    }

    private func assertPlainExpression(_ expression: VRM1.Expressions.Expression?,
                                       morphTargetIndices: [Int]?,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(expression?.morphTargetBinds?.count == morphTargetIndices?.count, sourceLocation: sourceLocation)
        for (position, index) in (morphTargetIndices ?? []).enumerated() {
            #expect(expression?.morphTargetBinds?[position].node == 2, sourceLocation: sourceLocation)
            #expect(expression?.morphTargetBinds?[position].index == index, sourceLocation: sourceLocation)
            #expect(expression?.morphTargetBinds?[position].weight == 1, sourceLocation: sourceLocation)
        }
        #expect(expression?.materialColorBinds?.count == nil, sourceLocation: sourceLocation)
        #expect(expression?.textureTransformBinds?.count == nil, sourceLocation: sourceLocation)
        #expect(expression?.isBinary == false, sourceLocation: sourceLocation)
        #expect(expression?.overrideBlink == ExpressionOverride.none, sourceLocation: sourceLocation)
        #expect(expression?.overrideLookAt == ExpressionOverride.none, sourceLocation: sourceLocation)
        #expect(expression?.overrideMouth == ExpressionOverride.none, sourceLocation: sourceLocation)
    }
    
    @Test
    func testSpringBone() {
        #expect(vrm.springBone?.specVersion == "1.0")
        assertColliders()
        assertColliderGroups()
        assertSprings()
    }

    /// Every collider of the fixture is a capsule but one, and each hangs off a node
    /// with an offset and a radius.
    private func assertColliders() {
        #expect(vrm.springBone?.colliders?.count == 8)
        assertCapsuleCollider(0, node: 4,
                              offset: [-0.04, 0, 0.02],
                              radius: 0.088,
                              tail: [0.04, 0, 0.02])
        assertSphereCollider(1, node: 5,
                             offset: [0, 0.02, -0.07],
                             radius: 0.113)
        assertCapsuleCollider(2, node: 5,
                              offset: [0.065, 0.14, 0.01],
                              radius: 0.083,
                              tail: [-0.065, 0.14, 0.01])
        assertCapsuleCollider(3, node: 5,
                              offset: [0.04, 0, 0.02],
                              radius: 0.083,
                              tail: [-0.04, 0, 0.02])
        assertCapsuleCollider(4, node: 130,
                              offset: [-0.004536999, 7.566095e-9, 0.0127928918],
                              radius: 0.07,
                              tail: [-0.001991607, 0.329534262, 0.009325488])
        assertCapsuleCollider(5, node: 131,
                              offset: [4.570225e-9, -1.477034e-8, 0.008859742],
                              radius: 0.065,
                              tail: [2.013798e-8, 0.3535266, 0.008811156])
        assertCapsuleCollider(6, node: 137,
                              offset: [0.004536999, 7.566095e-9, 0.0127928918],
                              radius: 0.07,
                              tail: [0.001991607, 0.329534262, 0.009325488])
        assertCapsuleCollider(7, node: 138,
                              offset: [-4.57022464e-9, -1.477034e-8, 0.008859742],
                              radius: 0.065,
                              tail: [-2.013798e-8, 0.3535266, 0.008811156])
    }

    private func assertCapsuleCollider(_ index: Int,
                                       node: Int,
                                       offset: [Double],
                                       radius: Double,
                                       tail: [Double],
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .capsule(let capsule) = vrm.springBone?.colliders?[index].shape else {
            Issue.record("collider \(index) is not a capsule", sourceLocation: sourceLocation)
            return
        }
        #expect(vrm.springBone?.colliders?[index].node == node, sourceLocation: sourceLocation)
        assertComponents(capsule.offset, offset, sourceLocation: sourceLocation)
        #expect(capsule.radius == radius, sourceLocation: sourceLocation)
        assertComponents(capsule.tail, tail, sourceLocation: sourceLocation)
    }

    private func assertSphereCollider(_ index: Int,
                                      node: Int,
                                      offset: [Double],
                                      radius: Double,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .sphere(let sphere) = vrm.springBone?.colliders?[index].shape else {
            Issue.record("collider \(index) is not a sphere", sourceLocation: sourceLocation)
            return
        }
        #expect(vrm.springBone?.colliders?[index].node == node, sourceLocation: sourceLocation)
        assertComponents(sphere.offset, offset, sourceLocation: sourceLocation)
        #expect(sphere.radius == radius, sourceLocation: sourceLocation)
    }

    /// Checks a vector one component at a time so a mismatch names the component rather
    /// than printing two whole arrays.
    private func assertComponents(_ vector: SIMD3<Float>?,
                                  _ expected: [Double],
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        for (position, value) in expected.enumerated() {
            #expect(vector?[position] == Float(value), sourceLocation: sourceLocation)
        }
    }

    private func assertComponents(_ vector: [Double]?,
                                  _ expected: [Double],
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(vector?.count == expected.count, sourceLocation: sourceLocation)
        for (position, value) in expected.enumerated() {
            #expect(vector?[position] == value, sourceLocation: sourceLocation)
        }
    }

    private func assertColliderGroups() {
        #expect(vrm.springBone?.colliderGroups?.count == 2)
        assertColliderGroup(0, colliders: [0, 1, 2, 3])
        assertColliderGroup(1, colliders: [6, 7, 4, 5])
    }

    private func assertColliderGroup(_ index: Int,
                                     colliders: [Int],
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        let group = vrm.springBone?.colliderGroups?[index]
        #expect(group?.colliders.count == colliders.count, sourceLocation: sourceLocation)
        for (position, collider) in colliders.enumerated() {
            #expect(group?.colliders[position] == collider, sourceLocation: sourceLocation)
        }
    }

    /// The fixture springs the tail hair, seven strands of front hair and the robot wire,
    /// and only the first and the last meet a collider.
    private func assertSprings() {
        #expect(vrm.springBone?.springs?.count == 9)
        assertTailHairSpring()
        assertFrontHairSpring(1, name: "FrontHairA", jointNodes: [47, 48])
        assertFrontHairSpring(2, name: "FrontHairB", jointNodes: [50, 51])
        assertFrontHairSpring(3, name: "FrontHairC", jointNodes: [53, 54])
        assertFrontHairSpring(4, name: "FrontHairD", jointNodes: [56, 57])
        assertFrontHairSpring(5, name: "FrontHairE", jointNodes: [59, 60])
        assertFrontHairSpring(6, name: "FrontHairF", jointNodes: [62, 63])
        assertFrontHairSpring(7, name: "FrontHairG", jointNodes: [65, 66])
        assertRoboWireSpring()
    }

    /// The tail hair runs over seven joints that soften towards its tip.
    private func assertTailHairSpring() {
        let spring = vrm.springBone?.springs?[0]
        #expect(spring?.center == 3)
        #expect(spring?.colliderGroups?.count == 1)
        #expect(spring?.colliderGroups?[0] == 0)
        #expect(spring?.joints.count == 7)
        let stiffnesses: [Double] = [4, 4, 3, 3, 2, 2, 2]
        for (position, stiffness) in stiffnesses.enumerated() {
            assertJoint(spring?.joints[position], node: 75 + position, hitRadius: 0.02, stiffness: stiffness)
        }
        #expect(spring?.name == "TailHair")
    }

    /// Every strand of front hair is two equally soft joints centred on the hips and
    /// touched by no collider.
    private func assertFrontHairSpring(_ index: Int,
                                       name: String,
                                       jointNodes: [Int],
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        let spring = vrm.springBone?.springs?[index]
        #expect(spring?.center == 3, sourceLocation: sourceLocation)
        #expect(spring?.joints.count == jointNodes.count, sourceLocation: sourceLocation)
        for (position, node) in jointNodes.enumerated() {
            assertJoint(spring?.joints[position],
                        node: node,
                        hitRadius: 0.01,
                        stiffness: 1.2,
                        sourceLocation: sourceLocation)
        }
        #expect(spring?.name == name, sourceLocation: sourceLocation)
    }

    /// The robot wire is uniformly stiff and thickens at its sixth joint.
    private func assertRoboWireSpring() {
        let spring = vrm.springBone?.springs?[8]
        #expect(spring?.colliderGroups?.count == 1)
        #expect(spring?.colliderGroups?[0] == 1)
        #expect(spring?.joints.count == 7)
        let hitRadii: [Double] = [0.02, 0.02, 0.02, 0.02, 0.02, 0.06, 0.02]
        for (position, hitRadius) in hitRadii.enumerated() {
            assertJoint(spring?.joints[position], node: 37 + position, hitRadius: hitRadius, stiffness: 4)
        }
        #expect(spring?.name == "RoboWire")
    }

    /// Every joint of the fixture drags at full force and aims its gravity straight
    /// down at no power at all.
    private func assertJoint(_ joint: VRM1.SpringBone.Spring.Joint?,
                             node: Int,
                             hitRadius: Double,
                             stiffness: Double,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(joint?.dragForce == 1, sourceLocation: sourceLocation)
        assertComponents(joint?.gravityDir, [0, -1, 0], sourceLocation: sourceLocation)
        #expect(joint?.gravityPower == 0, sourceLocation: sourceLocation)
        #expect(joint?.hitRadius == hitRadius, sourceLocation: sourceLocation)
        #expect(joint?.node == node, sourceLocation: sourceLocation)
        #expect(joint?.stiffness == stiffness, sourceLocation: sourceLocation)
    }

    @Test
    func testMaterialsMToon() {
        assertMToonMaterials()
        assertMaterialsWithoutMToon()
    }

    /// Every MToon material of the fixture shares its outline and rim lighting mix,
    /// render queue, spec version, opaque z write and still UV animation. Only the
    /// factors and the textures below differ.
    private func assertMToonMaterials() {
        assertMToonMaterial(0,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0, 0, 0],
                            outlineWidthFactor: 0.0005,
                            outlineWidthMode: .worldCoordinates,
                            outlineWidthMultiplyTextureIndex: 1,
                            parametricRimColorFactor: [0, 0, 0],
                            parametricRimFresnelPowerFactor: 1,
                            parametricRimLiftFactor: 0,
                            shadeColorFactor: [0.301212043, 0.301212043, 0.301212043],
                            shadeMultiplyTextureIndex: 0,
                            shadingShiftFactor: -0.05,
                            shadingToonyFactor: 0.95)
        assertMToonMaterial(1,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0.151317075, 0.193065077, 0.222877234],
                            outlineWidthFactor: 0.0015,
                            outlineWidthMode: .worldCoordinates,
                            parametricRimColorFactor: [0, 0, 0],
                            parametricRimFresnelPowerFactor: 1,
                            parametricRimLiftFactor: 0,
                            shadeColorFactor: [0.20541285, 0.20541285, 0.20541285],
                            shadeMultiplyTextureIndex: 2,
                            shadingShiftFactor: -0.1,
                            shadingToonyFactor: 0.9)
        assertMToonMaterial(2,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0.2411783, 0.181807414, 0.1557278],
                            outlineWidthFactor: 0.0011,
                            outlineWidthMode: .worldCoordinates,
                            outlineWidthMultiplyTextureIndex: 6,
                            parametricRimColorFactor: [0, 0, 0],
                            parametricRimFresnelPowerFactor: 1,
                            parametricRimLiftFactor: 0,
                            shadeColorFactor: [1, 0.613979936, 0.5079454],
                            shadeMultiplyTextureIndex: 4,
                            shadingShiftFactor: -0.2,
                            shadingShiftTextureIndex: 5,
                            shadingShiftTextureScale: 1,
                            shadingToonyFactor: 0.8)
        assertMToonMaterial(3,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0, 0, 0],
                            outlineWidthFactor: 0.5,
                            outlineWidthMode: .none,
                            parametricRimColorFactor: [0, 0, 0],
                            parametricRimFresnelPowerFactor: 1,
                            parametricRimLiftFactor: 0,
                            shadeColorFactor: [0.4352691, 0.3970382, 0.500747442],
                            shadeMultiplyTextureIndex: 7,
                            shadingShiftFactor: -0.2,
                            shadingToonyFactor: 0.8)
        assertMToonMaterial(4,
                            giEqualizationFactor: 0.5,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0, 0, 0],
                            outlineWidthFactor: 0.5,
                            outlineWidthMode: .none,
                            parametricRimColorFactor: [0, 0, 0],
                            parametricRimFresnelPowerFactor: 1,
                            parametricRimLiftFactor: 0,
                            shadeColorFactor: [1, 1, 1],
                            shadingShiftFactor: -0.2,
                            shadingToonyFactor: 0.8)
        assertMToonMaterial(5,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0, 0, 0],
                            outlineWidthFactor: 0.0015,
                            outlineWidthMode: .worldCoordinates,
                            parametricRimColorFactor: [0.07896994, 0.07896994, 0.07896994],
                            parametricRimFresnelPowerFactor: 4.3,
                            parametricRimLiftFactor: 0.182,
                            shadeColorFactor: [0.4352691, 0.3970382, 0.500747442],
                            shadeMultiplyTextureIndex: 8,
                            shadingShiftFactor: -0.1,
                            shadingToonyFactor: 0.9)
        assertMToonMaterial(6,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [1, 1, 1],
                            matcapTextureIndex: 9,
                            outlineColorFactor: [0.07896994, 0.07896994, 0.07896994],
                            outlineWidthFactor: 0.002,
                            outlineWidthMode: .worldCoordinates,
                            parametricRimColorFactor: [0.345616162, 0.345616162, 0.345616162],
                            parametricRimFresnelPowerFactor: 3.2,
                            parametricRimLiftFactor: 0.15,
                            shadeColorFactor: [0.342953056, 0.37243554, 0.432035774],
                            shadeMultiplyTextureIndex: 8,
                            shadingShiftFactor: -0.1,
                            shadingToonyFactor: 0.9)
        assertMToonMaterial(8,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0.01850021, 0.0176419467, 0.0251868479],
                            outlineWidthFactor: 0.001,
                            outlineWidthMode: .worldCoordinates,
                            parametricRimColorFactor: [0, 0, 0],
                            parametricRimFresnelPowerFactor: 1,
                            parametricRimLiftFactor: 0,
                            shadeColorFactor: [0.4352691, 0.3970382, 0.500747442],
                            shadeMultiplyTextureIndex: 4,
                            shadingShiftFactor: -0.2,
                            shadingToonyFactor: 0.8)
        assertMToonMaterial(10,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [1, 1, 1],
                            matcapTextureIndex: 9,
                            outlineColorFactor: [0.009166719, 0.009166719, 0.009166719],
                            outlineWidthFactor: 0.001,
                            outlineWidthMode: .worldCoordinates,
                            parametricRimColorFactor: [0.432035774, 0.432035774, 0.432035774],
                            parametricRimFresnelPowerFactor: 7.9,
                            parametricRimLiftFactor: 0.153,
                            shadeColorFactor: [0.4352691, 0.3970382, 0.500747442],
                            shadeMultiplyTextureIndex: 2,
                            shadingShiftFactor: -0.1,
                            shadingToonyFactor: 0.9)
        assertMToonMaterial(11,
                            giEqualizationFactor: 0.9,
                            matcapFactor: [0, 0, 0],
                            outlineColorFactor: [0, 0, 0],
                            outlineWidthFactor: 0.5,
                            outlineWidthMode: .none,
                            parametricRimColorFactor: [0, 0, 0],
                            parametricRimFresnelPowerFactor: 1,
                            parametricRimLiftFactor: 0,
                            shadeColorFactor: [1, 1, 1],
                            shadeMultiplyTextureIndex: 12,
                            shadingShiftFactor: -0.1,
                            shadingToonyFactor: 0.9)
    }

    private func assertMToonMaterial(_ index: Int,
                                     giEqualizationFactor: Double,
                                     matcapFactor: [Double],
                                     matcapTextureIndex: Int? = nil,
                                     outlineColorFactor: [Double],
                                     outlineWidthFactor: Double,
                                     outlineWidthMode: MToonOutlineWidthMode,
                                     outlineWidthMultiplyTextureIndex: Int? = nil,
                                     parametricRimColorFactor: [Double],
                                     parametricRimFresnelPowerFactor: Double,
                                     parametricRimLiftFactor: Double,
                                     shadeColorFactor: [Double],
                                     shadeMultiplyTextureIndex: Int? = nil,
                                     shadingShiftFactor: Double,
                                     shadingShiftTextureIndex: Int? = nil,
                                     shadingShiftTextureScale: Double? = nil,
                                     shadingToonyFactor: Double,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        let mToon = vrm.document.gltf.materials[index].extensions?.materialsMToon
        #expect(mToon?.giEqualizationFactor == giEqualizationFactor, sourceLocation: sourceLocation)
        assertComponents(mToon?.matcapFactor, matcapFactor, sourceLocation: sourceLocation)
        #expect(mToon?.matcapTexture?.index == matcapTextureIndex, sourceLocation: sourceLocation)
        assertComponents(mToon?.outlineColorFactor, outlineColorFactor, sourceLocation: sourceLocation)
        #expect(mToon?.outlineLightingMixFactor == 1, sourceLocation: sourceLocation)
        #expect(mToon?.outlineWidthFactor == outlineWidthFactor, sourceLocation: sourceLocation)
        #expect(mToon?.outlineWidthMode == outlineWidthMode, sourceLocation: sourceLocation)
        #expect(mToon?.outlineWidthMultiplyTexture?.index == outlineWidthMultiplyTextureIndex, sourceLocation: sourceLocation)
        assertComponents(mToon?.parametricRimColorFactor, parametricRimColorFactor, sourceLocation: sourceLocation)
        #expect(mToon?.parametricRimFresnelPowerFactor == parametricRimFresnelPowerFactor, sourceLocation: sourceLocation)
        #expect(mToon?.parametricRimLiftFactor == parametricRimLiftFactor, sourceLocation: sourceLocation)
        #expect(mToon?.renderQueueOffsetNumber == 0, sourceLocation: sourceLocation)
        #expect(mToon?.rimLightingMixFactor == 1, sourceLocation: sourceLocation)
        assertComponents(mToon?.shadeColorFactor, shadeColorFactor, sourceLocation: sourceLocation)
        #expect(mToon?.shadeMultiplyTexture?.index == shadeMultiplyTextureIndex, sourceLocation: sourceLocation)
        #expect(mToon?.shadingShiftFactor == shadingShiftFactor, sourceLocation: sourceLocation)
        #expect(mToon?.shadingShiftTexture?.index == shadingShiftTextureIndex, sourceLocation: sourceLocation)
        #expect(mToon?.shadingShiftTexture?.scale == shadingShiftTextureScale, sourceLocation: sourceLocation)
        #expect(mToon?.shadingToonyFactor == shadingToonyFactor, sourceLocation: sourceLocation)
        #expect(mToon?.specVersion == "1.0", sourceLocation: sourceLocation)
        #expect(mToon?.transparentWithZWrite == false, sourceLocation: sourceLocation)
        #expect(mToon?.uvAnimationRotationSpeedFactor == 0, sourceLocation: sourceLocation)
        #expect(mToon?.uvAnimationScrollXSpeedFactor == 0, sourceLocation: sourceLocation)
        #expect(mToon?.uvAnimationScrollYSpeedFactor == 0, sourceLocation: sourceLocation)
    }

    /// The rest of the fixture's materials are shaded by plain glTF and carry no MToon
    /// extension at all.
    private func assertMaterialsWithoutMToon() {
        for index in [7, 9, 12, 13, 14, 15, 16] {
            #expect(vrm.document.gltf.materials[index].extensions?.materialsMToon == nil)
        }
    }

    @Test
    func testNodeConstraint() {
        // Nodes 14...35 are each rotation-constrained by one node, node 85 being the one
        // gap in the sources they name.
        let sources = Array(82...84) + Array(86...104)
        for (node, source) in zip(14...35, sources) {
            let constraint = vrm.document.gltf.nodes[node].extensions?.nodeConstraint
            #expect(constraint?.specVersion == "1.0")
            guard case .rotation(let rotation) = constraint?.constraint else {
                Issue.record("node \(node) is not rotation-constrained")
                continue
            }
            #expect(rotation.source == source)
            #expect(rotation.weight == 1)
        }
    }

    /// The version decides how everything else is read, so a document carrying both
    /// extensions, or neither, is refused rather than guessed at.
    @Test
    func testADocumentThatIsNotOneVRMIsRefused() throws {
        let both = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var extensions = json.object("extensions") ?? [:]
            extensions["VRMC_vrm"] = ["specVersion": "1.0"]
            json["extensions"] = .object(extensions)
        }
        let neither = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            json.removeValue(forKey: "extensions")
        }

        for data in [both, neither] {
            #expect(throws: VRMError.self) { try VRM(data: data) }
        }
    }

    /// `VRMC_node_constraint` defines exactly one of roll, aim and rotation;
    /// none or several says nothing about how the node is driven.
    @Test
    func testANodeConstraintMustDefineExactlyOneKind() throws {
        for constraint: JSONValue in [[:], ["roll": ["source": 0, "rollAxis": "X"], "rotation": ["source": 1]]] {
            let data = try VRMSampleAsset.seedSan.rewritingJSON { json in
                var nodes = json.objects("nodes")
                nodes[14]["extensions"] = ["VRMC_node_constraint": ["specVersion": "1.0", "constraint": constraint]]
                json["nodes"] = .objects(nodes)
            }
            #expect(throws: (any Error).self) { try VRM1(data: data) }
        }
    }

    /// The extension carries its own version, and a constraint of one this cannot read
    /// would be solved as if it said something else.
    @Test
    func testAnUnsupportedNodeConstraintSpecVersionLoadsUnconstrained() throws {
        typealias NodeConstraint = GLTF.Node.NodeExtensions.NodeConstraint
        #expect(NodeConstraint.supports(specVersion: "1.0"))
        #expect(NodeConstraint.supports(specVersion: "1.0-beta"))
        #expect(!NodeConstraint.supports(specVersion: "2.0"))

        let data = try VRMSampleAsset.seedSan.rewritingJSON { json in
            var nodes = json.objects("nodes")
            var constraint = try #require(nodes[14].object("extensions")?.object("VRMC_node_constraint"))
            constraint["specVersion"] = "2.0"
            nodes[14]["extensions"] = ["VRMC_node_constraint": .object(constraint)]
            json["nodes"] = .objects(nodes)
        }
        // Decoded leniently: the node just goes unconstrained, and the raw JSON still
        // carries what the document wrote.
        let vrm = try VRM1(data: data)
        let raised = vrm.document.gltf.nodes[14].extensions?.nodeConstraint
        #expect(raised?.specVersion == "2.0")
        #expect(raised?.constraint == nil)
    }
}
