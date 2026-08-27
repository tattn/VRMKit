#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Loading a model without blocking the caller. The vertex data is conditioned
/// off the actor the entity graph is built on, so what comes back has to be the
/// same model either way.
@Suite
@MainActor
struct AsyncLoadingTests {
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func meshShape(of entity: Entity) -> [(name: String, vertices: Int, triangles: Int)] {
        var shape: [(name: String, vertices: Int, triangles: Int)] = []
        var stack = [entity]
        while let next = stack.popLast() {
            stack.append(contentsOf: next.children)
            guard let model = next.components[ModelComponent.self] else { continue }
            let parts = model.mesh.contents.models.flatMap { Array($0.parts) }
            shape.append((next.name,
                          parts.reduce(0) { $0 + $1.positions.count },
                          parts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) / 3 }))
        }
        return shape.sorted { $0.name < $1.name }
    }

    /// The primitives are decoded concurrently, so what a load builds must not
    /// depend on the order they happen to finish in.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testEveryLoadOfAModelBuildsTheSameMeshes(asset: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let first = meshShape(of: try await VRMEntityLoader(withData: asset.data).loadEntity())
        let second = meshShape(of: try await VRMEntityLoader(withData: asset.data).loadEntity())

        #expect(!first.isEmpty)
        #expect(first.count == second.count)
        for (left, right) in zip(first, second) {
            #expect(left.name == right.name)
            #expect(left.vertices == right.vertices)
            #expect(left.triangles == right.triangles)
        }
    }

    /// A load that was cancelled stops reading vertices rather than finishing
    /// the model it was told to stop building.
    @Test
    func testACancelledLoadStopsBeforeItBuildsAnything() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data)

        let load = Task { try await loader.loadEntity() }
        load.cancel()

        await #expect(throws: CancellationError.self) { try await load.value }
        // The loader stays usable, so a cancelled load leaves nothing it prepared behind.
        #expect(loader.entityData.primitiveGeometries.isEmpty)
        #expect(loader.entityData.images.allSatisfy { $0 == nil })
    }

    /// The texture prepare pass conditions what the scene draws with, as the
    /// geometry one does.
    @Test
    func testPreparingDecodesOnlyTheImagesTheSceneDrawsWith() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // A second scene drawing none of the document's nodes.
        let loader = try TestSupport.loader(.simpleTexture) { json in
            json["scenes"] = .objects(json.objects("scenes") + [["nodes": .array([])]])
        }

        try await loader.prepareTextures(forSceneIndex: 1)
        #expect(loader.entityData.images.allSatisfy { $0 == nil })

        try await loader.prepareTextures(forSceneIndex: 0)
        #expect(loader.entityData.images.contains { $0 != nil })
    }

    /// The prepare pass reports what it cannot decode rather than leaving the
    /// build to find it again.
    @Test
    func testAMalformedPrimitiveFailsTheLoadWhilePreparing() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let broken = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            var meshes = json.objects("meshes")
            var primitives = meshes[0].objects("primitives")
            primitives[0]["indices"] = 999
            meshes[0]["primitives"] = .objects(primitives)
            json["meshes"] = .objects(meshes)
        }
        let loader = try GLTFEntityLoader(withData: broken,
                                          rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory)

        await #expect(throws: (any Error).self) {
            try await loader.prepareGeometry(forSceneIndex: loader.gltf.defaultSceneIndex())
        }
        await #expect(throws: (any Error).self) { try await loader.loadEntity() }
    }

    /// Preparing decodes each primitive once, and the build takes what is already
    /// there rather than expanding the accessors again. It takes rather than reads,
    /// since the vertex data would otherwise be a second copy of the model.
    @Test
    func testPreparingDecodesEveryPrimitiveOfTheSceneOnce() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data)
        let sceneIndex = loader.gltf.scene ?? 0

        try await loader.prepareGeometry(forSceneIndex: sceneIndex)
        let prepared = loader.entityData.primitiveGeometries.count
        _ = try await loader.loadEntity(withSceneIndex: sceneIndex)

        #expect(prepared > 0)
        #expect(loader.entityData.primitiveGeometries.isEmpty)
    }

    /// A second load of the same scene clones the mesh templates the first one
    /// built, so preparing for it reads no vertex at all.
    @Test
    func testLoadingASceneASecondTimeDecodesNoPrimitive() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data)
        let sceneIndex = loader.gltf.scene ?? 0

        _ = try await loader.loadEntity(withSceneIndex: sceneIndex)
        try await loader.prepareGeometry(forSceneIndex: sceneIndex)

        #expect(loader.entityData.primitiveGeometries.isEmpty)
        #expect(!loader.entityData.meshTemplates.isEmpty)
    }
}
#endif
