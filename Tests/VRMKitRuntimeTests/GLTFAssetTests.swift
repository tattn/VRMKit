import Foundation
import SIMDCompat
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMKitRuntime

/// What a scene draws, read with no renderer: the nodes, the skins parents first, and one
/// mesh per way a node draws a glTF mesh, its slots each naming their material.
@Suite
struct GLTFAssetTests {
    @Test(arguments: VRMSampleAsset.allCases)
    func testEveryMeshAVRMDrawsIsReadWithItsSlotsMaterials(asset: VRMSampleAsset) async throws {
        let vrm = try VRM(data: asset.data)
        let read = try await GLTFAsset.load(vrm: vrm)

        #expect(read.nodes.count == vrm.document.gltf.nodes.count)
        #expect(!read.meshes.isEmpty)
        for mesh in read.meshes {
            #expect(mesh.materialIndices.count == mesh.geometry.slots.count)
            #expect(mesh.geometry.vertexCount > 0)
        }
        for (node, index) in read.meshIndicesByNode {
            #expect(read.nodes[node].mesh == read.meshes[index].meshIndex)
        }
    }

    /// A joint never comes before the joint it hangs off, so a pose can be solved in order.
    @Test(arguments: VRMSampleAsset.allCases)
    func testSkinJointsFollowTheirParents(asset: VRMSampleAsset) async throws {
        let read = try await GLTFAsset.load(vrm: try VRM(data: asset.data))
        #expect(!read.skins.isEmpty)
        for skin in read.skins {
            #expect(skin.joints.count == skin.parents.count)
            #expect(skin.joints.count == skin.inverseBindMatrices.count)
            for (joint, parent) in skin.parents.enumerated() {
                guard let parent else { continue }
                #expect(parent < joint)
                #expect(ancestors(of: skin.joints[joint], in: read).contains(skin.joints[parent]))
            }
        }
    }

    /// VRM's first-person settings cut the head out of the meshes a first-person camera draws.
    @Test
    func testAVRMMeshDrawnWithTheHeadCutCarriesTheFirstPersonTriangles() async throws {
        let read = try await GLTFAsset.load(vrm: try VRM(data: VRMSampleAsset.aliciaSolid.data))
        let cut = read.meshes.filter(\.cutsHead)
        #expect(!cut.isEmpty)
        #expect(cut.contains { $0.geometry.slots.contains { $0.firstPersonIndexRange != nil } })
    }

    @Test
    func testAPlainGLTFReadsItsSkinAndMorphTargets() async throws {
        let skinned = try await GLTFAsset.load(document: try GLTFDocument(withURL: GLTFSampleAsset.simpleSkin.url))
        let skinnedMesh = try #require(skinned.meshes.first)
        #expect(skinnedMesh.skinIndex == 0)
        #expect(skinnedMesh.geometry.isSkinned)
        #expect(skinnedMesh.materialIndices == [nil])

        let morphed = try await GLTFAsset.load(document: try GLTFDocument(withURL: GLTFSampleAsset.simpleMorph.url))
        let morphedMesh = try #require(morphed.meshes.first)
        #expect(morphedMesh.geometry.blendShapeTargetCount == 2)
        let node = try #require(morphed.meshIndicesByNode.keys.first)
        #expect(morphed.nodes[node].initialMorphWeights == [0.5, 0.5])
    }

    private func ancestors(of node: Int, in asset: GLTFAsset) -> [Int] {
        var ancestors: [Int] = []
        var current = asset.nodes[node].parent
        while let parent = current {
            ancestors.append(parent)
            current = asset.nodes[parent].parent
        }
        return ancestors
    }
}
