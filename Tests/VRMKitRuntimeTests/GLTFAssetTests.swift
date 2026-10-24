import Foundation
import SIMDCompat
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMKitRuntime

/// What a scene draws, read with no renderer: the nodes, the skins parents first, one mesh
/// per way a node draws a glTF mesh, its slots each naming their material, the materials as
/// read and the images as stored.
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

    // MARK: - Materials and images

    /// A VRM 1.0 model's materials read as MToon, and the images they sample say how they are read.
    @Test
    func testAVRM1ModelsMaterialsReadAsMToon() async throws {
        let read = try await GLTFAsset.load(vrm: try VRM(data: VRMSampleAsset.seedSan.data))
        #expect(read.materials.count == read.document.gltf.materials.count)
        let mtoon = read.materials.compactMap { material -> MToonMaterialDescriptor? in
            guard case .mtoon(let descriptor) = material.shading else { return nil }
            return descriptor
        }
        #expect(!mtoon.isEmpty)
        let base = try #require(mtoon.compactMap(\.baseColorTexture).first)
        #expect(read.images[try read.imageIndex(ofTexture: base.index)].usages.contains(.color))
        for material in read.materials {
            #expect((material.renderQueue != nil) == (material.alphaMode == .BLEND))
        }
    }

    /// VRM 0.x shader metadata decides how a material draws: an unlit shader reads flat, and
    /// a transparent one blends in the queue the model recorded.
    @Test
    func testAVRM0ModelsUnlitShadersReadFlatInTheirRecordedQueue() async throws {
        let vrm = try VRM(data: VRMSampleAsset.aliciaSolid.data)
        let read = try await GLTFAsset.load(vrm: vrm)
        for material in read.materials {
            guard case .unlit = material.shading else {
                Issue.record("material \(material.index) reads as \(material.shading)")
                continue
            }
            let property = try #require(vrm.vrm0MaterialProperty(at: material.index))
            #expect(material.renderQueue == (material.alphaMode == .BLEND ? property.renderQueue : nil))
        }
        #expect(read.materials.contains { $0.alphaMode == .BLEND })
        #expect(read.images.contains { $0.usages == [.color] })
    }

    @Test
    func testAPlainGLTFsImageIsReadAsStored() async throws {
        let read = try await GLTFAsset.load(document: try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url))
        let material = try #require(read.materials.first)
        guard case .physicallyBased = material.shading else {
            Issue.record("a metallic-roughness material reads as \(material.shading)")
            return
        }
        let image = try #require(read.images.first)
        #expect(image.usages == [.color])
        #expect(image.mimeType == "image/png")
        #expect(try image.data().starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(try read.sampler(ofTexture: 0) != nil)
    }

    /// `KHR_texture_transform` is read once per material, off its first UV-accessed texture.
    @Test
    func testAMaterialReadsThroughItsFirstTexturesTransform() async throws {
        let read = try await GLTFAsset.load(document: try GLTFDocument(withURL: GLTFSampleAsset.textureTransformTest.url))
        #expect(read.materials[0].uvTransform.offset == SIMD2(0.5, 0))
        #expect(read.materials[1].uvTransform.offset == SIMD2(0, 0.5))
        #expect(abs(read.materials[3].uvTransform.rotation - 0.39269908) < 1e-6)
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
