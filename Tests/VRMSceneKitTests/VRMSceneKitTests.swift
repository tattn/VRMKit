import Testing
import VRMTestSupport
@testable import VRMSceneKit
import SceneKit

@Suite
struct VRMSceneKitTests {
    
    @Test
    func testHumanoid() throws {
        let humanoid = try loadVRM().humanoid
        #expect(humanoid.bones.count == 53)
        let neckPosition = humanoid.node(for: .neck)!.position
        #expect(round(neckPosition.x * 1000) == 0)
        #expect(round(neckPosition.y * 1000) == 140)
        #expect(round(neckPosition.z * 1000) == 14)
    }

    /// A VRM 0.x model's blend shape groups load as the expressions they stand
    /// for, so its runtime is the same one a 1.0 model gets.
    @Test
    func testBlendShapeGroupsLoadAsExpressionClips() throws {
        let clips = try loadVRM().expressionClips
        #expect(clips.count == 18)
        let clip = clips[.custom("><")]!
        #expect(clip.name == "><")
        #expect(clip.preset == nil)
        #expect(clip.key == .custom("><"))
        #expect(clip.isBinary == false)
        #expect(clip.values.count == 3)
        #expect(clip.values[0].index == 31)
        #expect(clip.values[0].weight == 100)
        #expect(clip.values[0].mesh.name == "face.baked")
        #expect(clips.filter({ $0.key.isPreset }).count == 17)
        #expect(clips.filter({ !$0.key.isPreset }).count == 1)
        // "joy" is what VRM 0.x calls the expression 1.0 calls "happy".
        #expect(clips[.preset(.happy)] != nil)
    }

    @Test
    func testExpression_SetAndGet() throws {
        let node = try loadVRM()
        node.setExpression(value: 0.85, for: .preset(.happy))
        #expect(round(node.expression(for: .preset(.happy)) * 100) == 85)
    }

    @Test
    func testVRM0MaterialsKeepConstantLighting() throws {
        let loader = try loadVRMLoader()
        let materialCount = loader.vrm.document.gltf.materials?.count ?? 0
        #expect(materialCount > 0)

        for index in 0..<materialCount {
            let material = try loader.material(withMaterialIndex: index)
            #expect(material.lightingModel == .constant, "Material \(index): \(material.name ?? "")")
            #expect(!(material.isLitPerPixel), "Material \(index): \(material.name ?? "")")
        }
    }

    func loadVRM() throws -> VRMNode {
        try loadVRMLoader().loadScene().vrmNode
    }

    func loadVRMLoader() throws -> VRMSceneLoader {
        try VRMSceneLoader(withData: VRMSampleAsset.aliciaSolid.data)
    }
}
