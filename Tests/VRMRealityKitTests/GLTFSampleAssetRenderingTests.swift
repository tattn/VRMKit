#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Renders the Khronos CC0 sample assets through ``GLTFEntityLoader``, covering what the
/// VRM fixtures cannot: JSON glTF with external resources, non-indexed geometry, plain
/// PBR materials, cameras and animations.
@Suite
@MainActor
struct GLTFSampleAssetRenderingTests {
    @Test(arguments: GLTFSampleAsset.allCases)
    func testEverySampleAssetLoadsIntoARenderableEntity(_ asset: GLTFSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(asset)

        // Every asset must produce drawable geometry, not just an empty graph.
        let modelEntities = entity.modelEntitiesInHierarchy
        #expect(!modelEntities.isEmpty, "\(asset.rawValue) produced no ModelEntity")
        for modelEntity in modelEntities {
            let model = try #require(modelEntity.components[ModelComponent.self])
            #expect(!model.materials.isEmpty)
            #expect(model.mesh.contents.models.contains { !$0.parts.isEmpty })
        }
    }

    /// The loader falls back to the default material when one fails to build and only
    /// logs it, so each material is built explicitly here.
    @Test(arguments: GLTFSampleAsset.allCases)
    func testEveryMaterialOfEverySampleAssetBuilds(_ asset: GLTFSampleAsset) throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withURL: asset.url)
        let materialCount = loader.document.gltf.materials.count

        for index in 0..<materialCount {
            #expect(throws: Never.self, "\(asset.rawValue) material \(index)") {
                _ = try loader.material(withMaterialIndex: index)
            }
        }
    }

    @Test
    func testIndexedAndNonIndexedTrianglesBothRenderThreeVertices() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for asset in [GLTFSampleAsset.triangle, .triangleWithoutIndices] {
            let entity = try await TestSupport.loadEntity(asset)
            let model = try #require(entity.modelEntitiesInHierarchy.first?.components[ModelComponent.self])
            let part = try #require(model.mesh.contents.models.first?.parts.first)

            #expect(part.positions.count == 3, "\(asset.rawValue)")
            #expect(part.triangleIndices?.count == 3, "\(asset.rawValue)")
        }
    }

    @Test
    func testTwoNodesSharingOneMeshBecomeTwoEntities() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.simpleMeshes)

        let first = try #require(entity.entity(forNodeAt: 0))
        let second = try #require(entity.entity(forNodeAt: 1))
        #expect(first !== second)
        #expect(!first.modelEntitiesInHierarchy.isEmpty)
        #expect(!second.modelEntitiesInHierarchy.isEmpty)
        // The second node carries the glTF translation of [1, 0, 0].
        #expect(second.transform.translation.isApproximatelyEqual(to: SIMD3<Float>(1, 0, 0)))
    }

    @Test
    func testExternalPNGTextureLoadsIntoTheMaterial() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withURL: GLTFSampleAsset.simpleTexture.url)
        let material = try #require(try loader.material(withMaterialIndex: 0) as? PhysicallyBasedMaterial)

        // The image is a sibling file of the .gltf, so a non-nil texture proves the root
        // directory reached the image loader.
        #expect(material.baseColor.texture != nil)
    }

    @Test
    func testSkinnedSampleGetsSkeletonAndInitialPose() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.simpleSkin)

        let binding = try #require(entity.skinBindings.first)
        // SimpleSkin's skin lists two joints, nodes 1 and 2.
        #expect(binding.jointEntities.count == 2)
        #expect(binding.jointEntities[0] === entity.entity(forNodeAt: 1))
        #expect(binding.jointEntities[1] === entity.entity(forNodeAt: 2))
        #expect(binding.modelEntity.components.has(SkeletalPosesComponent.self))
    }

    /// SimpleMorph declares `mesh.weights = [0.5, 0.5]` and no node weights, so it is the
    /// fixture for the `node.weights` → `mesh.weights` fallback.
    @Test
    func testInitialMorphWeightsFallBackToMeshWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.simpleMorph)

        let binding = try #require(entity.morphBindings[0])
        #expect(binding.targetCount == 2)
        let weights = try #require(binding.modelEntities.first?.blendWeights.first)
        #expect(weights.count == 2)
        #expect(weights.allSatisfy { $0.isApproximatelyEqual(to: 0.5) })
    }

    @Test
    func testCamerasBecomeCameraComponents() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.cameras)

        let perspectiveNode = try #require(entity.entity(forNodeAt: 1))
        let perspective = try #require(perspectiveNode.components[PerspectiveCameraComponent.self])
        #expect(perspective.near.isApproximatelyEqual(to: 0.01))
        #expect(perspective.far.isApproximatelyEqual(to: 100))
        // aspectRatio 1.0 with yfov 0.7 gives the same horizontal fov.
        #expect(perspective.fieldOfViewOrientation == .horizontal)
        #expect(perspective.fieldOfViewInDegrees.isApproximatelyEqual(to: 0.7 * 180 / .pi, tolerance: 0.01))

        let orthographicNode = try #require(entity.entity(forNodeAt: 2))
        let orthographic = try #require(orthographicNode.components[OrthographicCameraComponent.self])
        #expect(orthographic.near.isApproximatelyEqual(to: 0.01))
        #expect(orthographic.far.isApproximatelyEqual(to: 100))
        #expect(orthographic.scale.isApproximatelyEqual(to: 1))
    }

    /// A loaded animated model sits in its rest pose until something plays an animation.
    /// Playback itself is covered by GLTFAnimationPlaybackTests.
    @Test
    func testAnimatedSamplesRenderTheirRestPose() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedTriangle)

        let node = try #require(entity.entity(forNodeAt: 0))
        #expect(node.transform.rotation.vector.isApproximatelyEqual(to: SIMD4<Float>(0, 0, 0, 1)))
        #expect(entity.gltf.animations.isEmpty == false)
    }

    @Test
    func testAnimatedMorphCubeKeepsItsMorphBindings() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(GLTFSampleAsset.animatedMorphCube)

        // The weights channel targets a node, which has to resolve to the blend-shape
        // model entities the animation runtime writes to.
        let channel = try #require(entity.gltf.animations.first?.channels.first { $0.target.targetPath == .weights })
        let nodeIndex = try #require(channel.target.node)
        let binding = try #require(entity.morphBindings[nodeIndex])
        #expect(!binding.modelEntities.isEmpty)
        #expect(binding.modelEntities.allSatisfy { !$0.blendWeights.isEmpty })
    }

    /// glTF puts no restriction on where a skinned mesh sits, so it may hang below one of
    /// its own joints, whose entity is then asked for while its node is still being built.
    @Test
    func testSkinnedMeshBelowOneOfItsJointsResolvesToTheSameJointEntities() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // SimpleSkin's node 0 is the skinned mesh and its joints are nodes 1 / 2.
        let loader = try TestSupport.loader(.simpleSkin) { json in
            var nodes = json.objects("nodes")
            guard nodes.count == 3 else {
                throw VRMError.dataInconsistent("Missing SimpleSkin node fixture data")
            }
            nodes[1]["children"] = [2, 0]
            json["nodes"] = .objects(nodes)
            json["scenes"] = [["nodes": [1]]]
        }
        let entity = try await loader.loadEntity()

        let jointRoot = try #require(entity.entity(forNodeAt: 1))
        let meshNode = try #require(entity.entity(forNodeAt: 0))
        #expect(meshNode.parent === jointRoot)
        #expect(jointRoot.parent === entity)

        // The binding must drive this graph's joints, not a second copy of them.
        let binding = try #require(entity.skinBindings.first)
        #expect(binding.jointEntities.count == 2)
        #expect(binding.jointEntities[0] === jointRoot)
        #expect(binding.jointEntities[1] === entity.entity(forNodeAt: 2))
        #expect(TestSupport.isDescendant(binding.modelEntity, of: meshNode))
    }

    /// glTF requires every primitive of a skinned mesh to carry both skinning attributes,
    /// so a file missing one is malformed rather than unskinned.
    @Test
    func testSkinnedPrimitiveWithoutSkinningAttributesFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for dropped in ["JOINTS_0", "WEIGHTS_0"] {
            let loader = try TestSupport.loader(.simpleSkin) { json in
                var meshes = json.objects("meshes")
                var primitives = meshes.first?.objects("primitives") ?? []
                guard var attributes = primitives.first?.object("attributes") else {
                    throw VRMError.dataInconsistent("Missing SimpleSkin mesh fixture data")
                }
                attributes[dropped] = nil
                primitives[0]["attributes"] = .object(attributes)
                meshes[0]["primitives"] = .objects(primitives)
                json["meshes"] = .objects(meshes)
            }
            await #expect(throws: VRMError.self, "a skinned primitive without \(dropped)") {
                try await loader.loadEntity()
            }
        }
    }

    @Test
    func testKHRTextureTransformReachesPBRMaterials() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try GLTFEntityLoader(withURL: GLTFSampleAsset.textureTransformTest.url)

        func transform(_ index: Int) throws -> MaterialParameterTypes.TextureCoordinateTransform {
            let material = try #require(try loader.material(withMaterialIndex: index) as? PhysicallyBasedMaterial)
            return material.textureCoordinateTransform
        }

        // Offsets and scales carry over as-is; only the rotation direction mirrors, which
        // `TextureTransformRenderingTests` proves right.
        // Material 2 "Offset UV", 3 "Rotation" (π/8), 4 "Scale", 5 "All":
        #expect(try transform(2).offset.isApproximatelyEqual(to: SIMD2<Float>(0.5, 0.5)))
        #expect(try transform(3).rotation.isApproximatelyEqual(to: -0.39269908))
        #expect(try transform(4).scale.isApproximatelyEqual(to: SIMD2<Float>(1.5, 1.5)))

        let all = try transform(5)
        #expect(all.offset.isApproximatelyEqual(to: SIMD2<Float>(-0.2, -0.1)))
        #expect(all.rotation.isApproximatelyEqual(to: -0.3))
        #expect(all.scale.isApproximatelyEqual(to: SIMD2<Float>(1.5, 1.5)))

        // Material 6 "Correct" (no extension) stays identity.
        let identity = try transform(6)
        #expect(identity.offset.isApproximatelyEqual(to: SIMD2<Float>(0, 0)))
        #expect(identity.rotation.isApproximatelyEqual(to: 0))
        #expect(identity.scale.isApproximatelyEqual(to: SIMD2<Float>(1, 1)))
    }

}
#endif
