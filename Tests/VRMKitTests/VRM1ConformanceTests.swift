import Testing
import VRMKit
import VRMTestSupport

@Suite
struct VRM1ConformanceTests {
    @Test
    func testAvatarSampleMAddsFullHumanoidAndMaterialCoverage() throws {
        let vrm = try VRM1(data: VRMSampleAsset.avatarSampleM.data)
        let mtoonMaterials = vrm.document.gltf.materials.filter {
            $0.extensions?.materialsMToon != nil
        }

        #expect(vrm.humanoid.humanBones.bones.count == 54)
        #expect(vrm.expressions != nil)
        #expect(vrm.lookAt != nil)
        #expect(vrm.springBone != nil)
        #expect(mtoonMaterials.count == 6)
        #expect(vrm.document.gltf.nodes.allSatisfy {
            $0.extensions?.nodeConstraint == nil
        })
    }

    @Test
    func testSpecificationSampleCombinesThePhaseTwoFeatureSet() throws {
        let vrm = try VRM1(data: VRMSampleAsset.vrm1ConstraintTwist.data)
        let constrainedNodes = vrm.document.gltf.nodes.compactMap { $0.extensions?.nodeConstraint }
        let mtoonMaterials = vrm.document.gltf.materials.filter {
            $0.extensions?.materialsMToon != nil
        }

        #expect(vrm.expressions != nil)
        #expect(vrm.lookAt != nil)
        #expect(vrm.springBone != nil)
        #expect(mtoonMaterials.count > 0)
        #expect(vrm.humanoid.humanBones.bones.count > 15)
        #expect(constrainedNodes.contains { constraint in
            if case .roll = constraint.constraint { return true }
            return false
        })
        #expect(constrainedNodes.contains { constraint in
            if case .aim = constraint.constraint { return true }
            return false
        })
    }
}
