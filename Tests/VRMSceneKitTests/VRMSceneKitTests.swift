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
        // One binding per morpher rather than per bind, so that expressions
        // overlapping on a target accumulate onto the same one.
        #expect(clip.values.count == 3)
        #expect(clip.values[0].index == 31)
        #expect(clip.values[0].weight == 100)

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

    /// Primitives of a mesh sharing a POSITION accessor share the morph targets
    /// of whichever carries them, because that is how VRM exporters write them.
    /// One carrying its own keeps them, whatever the rest of the mesh says.
    @Test
    func testAPrimitiveKeepsItsOwnMorphTargets() throws {
        // The face mesh is three primitives over one POSITION accessor, of
        // which only the first carries targets; the second gets one of its own.
        let data = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var meshes = json.objects("meshes")
            var primitives = meshes[3].objects("primitives")
            primitives[1]["targets"] = [["POSITION": 33]]
            meshes[3]["primitives"] = .objects(primitives)
            json["meshes"] = .objects(meshes)
        }

        let scene = try VRMSceneLoader(withData: data).loadScene()

        let face = try #require(scene.vrmNode.childNodes(passingTest: { node, _ in
            node.name == "face.baked"
        }).first)
        let morphers = face.childNodes.map(\.morpher)
        #expect(morphers[0]?.targets.count == 49)
        #expect(morphers[1]?.targets.count == 1)
        #expect(morphers[0] !== morphers[1])
        // The third carries none, so it falls back to the shared one.
        #expect(morphers[2] === morphers[0])
    }

    /// Two expressions over one morph target add up rather than the second
    /// overwriting the first, and lowering one leaves the other's share behind.
    @Test
    func testExpressionsOverlappingOnATargetAccumulate() throws {
        let vrmNode = try loadVRM()
        let clips = vrmNode.expressionClips
        // A morph target more than one of the model's groups drives.
        var driving: [String: [ExpressionKey]] = [:]
        for (key, clip) in clips {
            for value in clip.values {
                driving["\(ObjectIdentifier(value.mesh))/\(value.index)", default: []].append(key)
            }
        }
        let shared = try #require(driving.values.first { $0.count >= 2 })
        let keys = Array(shared.sorted { "\($0)" < "\($1)" }.prefix(2))
        let binding = try #require(clips[keys[0]]?.values.first {
            shared.count == driving["\(ObjectIdentifier($0.mesh))/\($0.index)"]?.count
        })

        vrmNode.setExpression(value: 1, for: keys[0])
        let alone = binding.mesh.weight(forTargetAt: binding.index)
        vrmNode.setExpression(value: 1, for: keys[1])
        let together = binding.mesh.weight(forTargetAt: binding.index)
        vrmNode.setExpression(value: 0, for: keys[1])
        let backToOne = binding.mesh.weight(forTargetAt: binding.index)

        #expect(alone > 0)
        #expect(together > alone)
        #expect(abs(backToOne - alone) < 0.001)
    }

    func loadVRM() throws -> VRMNode {
        try loadVRMLoader().loadScene().vrmNode
    }

    func loadVRMLoader() throws -> VRMSceneLoader {
        try VRMSceneLoader(withData: VRMSampleAsset.aliciaSolid.data)
    }
}
