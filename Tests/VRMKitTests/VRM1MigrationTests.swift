import Testing
import VRMKit
import Foundation

struct VRM1MigrationTests {

    @Test("Meta: VRM1 -> VRM0")
    func migrationMetaVRM1toVRM0() throws {
        let vrm = try VRM(data: Resources.seedSan.data)

        // VRM1 data accessed via VRM0 format migration
        #expect(vrm.meta.title == "Seed-san")
        #expect(vrm.meta.author == "VirtualCast, Inc.")
        #expect(vrm.meta.version == "1")
        #expect(vrm.meta.texture == 14)
        #expect(vrm.meta.allowedUserName == "Everyone")
        #expect(vrm.meta.violentUssageName == "Allow")
        #expect(vrm.meta.sexualUssageName == "Allow")
        #expect(vrm.meta.commercialUssageName == "corporation")
        #expect(vrm.meta.licenseName == "https://vrm.dev/licenses/1.0/")
    }

    @Test("Humanoid: VRM1 -> VRM0")
    func migrationHumanoidVRM1toVRM0() throws {
        let vrm = try VRM(data: Resources.seedSan.data)

        // VRM1 data accessed via VRM0 format migration
        #expect(vrm.humanoid.humanBones.count == 51)
        #expect(vrm.humanoid.humanBones.first { $0.bone == "hips" }?.node == 3)
        #expect(vrm.humanoid.humanBones.first { $0.bone == "head" }?.node == 45)
    }

    @Test("BlendShape: VRM1 -> VRM0")
    func migrationBlendShapeVRM1toVRM0() throws {
        let vrm = try VRM(data: Resources.seedSan.data)

        #expect(vrm.blendShapeMaster.blendShapeGroups.count == 18)

        #expect(vrm.blendShapeMaster.blendShapeGroups.first { $0.name == "Happy" }?.presetName == "joy")
        #expect(vrm.blendShapeMaster.blendShapeGroups.first { $0.name == "Angry" }?.presetName == "angry")
        #expect(vrm.blendShapeMaster.blendShapeGroups.first { $0.name == "Sad" }?.presetName == "sorrow")
        #expect(vrm.blendShapeMaster.blendShapeGroups.first { $0.name == "Relaxed" }?.presetName == "fun")
        #expect(vrm.blendShapeMaster.blendShapeGroups.first { $0.name == "Surprised" }?.presetName == "unknown")
    }

    @Test("FirstPerson: VRM1 -> VRM0")
    func migrationFirstPersonVRM1toVRM0() throws {
        let vrm = try VRM(data: Resources.seedSan.data)

        #expect(vrm.firstPerson.meshAnnotations.count == 5)
        #expect(vrm.firstPerson.firstPersonBone == -1)
        #expect(vrm.firstPerson.lookAtTypeName == .blendShape)
    }

    @Test("SpringBone: VRM1 -> VRM0")
    func migrationSecondaryAnimationVRM1toVRM0() throws {
        let vrm = try VRM(data: Resources.seedSan.data)

        #expect(vrm.secondaryAnimation.colliderGroups.count == 6)

        #expect(vrm.secondaryAnimation.colliderGroups.contains { $0.node == 4 && $0.colliders.count == 1 })
        #expect(vrm.secondaryAnimation.colliderGroups.contains { $0.node == 5 && $0.colliders.count == 3 })
    }

    @Test("Material: MToon VRM1 -> VRM0")
    func migrationMaterialVRM1toVRM0() throws {
        let vrm = try VRM(data: Resources.seedSan.data)

        #expect(vrm.materialProperties.count == 17)

        // Material 0 (MToon)
        let mtoon0 = vrm.materialProperties[0]
        #expect(mtoon0.shader == "VRM/MToon")

        if let floatProps = mtoon0.floatProperties.value as? [String: Double] {
            #expect(floatProps["_ShadingToony"] == 0.95)
            #expect(floatProps["_ShadingShift"] == -0.05)
        } else {
            Issue.record("floatProperties type mismatch")
        }

        // _ShadeColor is vector
        if let vectorProps = mtoon0.vectorProperties.value as? [String: [Double]] {
            if let shadeColor = vectorProps["_ShadeColor"] {
                #expect(shadeColor.count == 4)
                // Approximate equality for double
                #expect(abs(shadeColor[0] - 0.301212043) < 0.0001)
            } else {
                Issue.record("_ShadeColor missing")
            }
        } else {
            Issue.record("vectorProperties type mismatch")
        }
    }

    @Test("VRM1 Version Detection")
    func versionDetection() throws {
        let vrm = try VRM(data: Resources.seedSan.data)

        guard case .v1(let vrm1) = vrm else {
            throw VRMError.dataInconsistent("Expected VRM1")
        }
        #expect(vrm.specVersion == "1.0")
        #expect(vrm1.meta.name == "Seed-san")
    }
}
