#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// The draw order of a mesh's blended materials: where each material lands on
/// Unity's render-queue scale, and the model entities the loader splits a mesh
/// into so that RealityKit keeps that order.
@Suite
@MainActor
struct RenderQueueTests {
    /// Seed-san's `head` mesh: the two eye materials it draws over `body_bake`.
    private static let opaqueEye = 3
    private static let blendedEye = 4

    @Test
    func testMToonQueueIsTheBlendModeBasePlusTheOffset() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let authored = try VRMEntityLoader(withData: TestSupport.seedSanData)
        #expect(try authored.shadedMaterial(withMaterialIndex: Self.blendedEye).renderQueue == 3000)
        #expect(try authored.shadedMaterial(withMaterialIndex: Self.opaqueEye).renderQueue == nil)

        let offset = try TestSupport.modifiedSeedSanMToonExtension(name: "queue-offset", index: Self.blendedEye) { mtoon in
            mtoon["renderQueueOffsetNumber"] = -3
        }
        #expect(try VRMEntityLoader(withData: offset).shadedMaterial(withMaterialIndex: Self.blendedEye).renderQueue == 2997)

        let zWrite = try TestSupport.modifiedSeedSanMToonExtension(name: "queue-zwrite", index: Self.blendedEye) { mtoon in
            mtoon["transparentWithZWrite"] = true
            mtoon["renderQueueOffsetNumber"] = 2
        }
        #expect(try VRMEntityLoader(withData: zWrite).shadedMaterial(withMaterialIndex: Self.blendedEye).renderQueue == 2503)
    }

    /// VRM 0.x records Unity's queue outright, for MToon and any other shader.
    @Test
    func testVRM0QueueIsTheRecordedOne() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // AliciaSolid's `Alicia_other` is an UnlitTransparent at Unity's default queue.
        let transparentOther = 5
        let authored = try VRMEntityLoader(withData: TestSupport.aliciaSolidData)
        #expect(try authored.shadedMaterial(withMaterialIndex: transparentOther).renderQueue == 3000)
        #expect(try authored.shadedMaterial(withMaterialIndex: 0).renderQueue == nil)

        let raised = try TestSupport.modifiedAliciaSolidData(name: "queue-3500") { json in
            var extensions = json.object("extensions") ?? [:]
            var vrm = extensions.object("VRM") ?? [:]
            var properties = vrm.objects("materialProperties")
            properties[transparentOther]["renderQueue"] = 3500
            vrm["materialProperties"] = .objects(properties)
            extensions["VRM"] = .object(vrm)
            json["extensions"] = .object(extensions)
        }
        #expect(try VRMEntityLoader(withData: raised).shadedMaterial(withMaterialIndex: transparentOther).renderQueue == 3500)
    }

    /// Blended parts sharing one queue stay parts of the mesh's one model entity,
    /// ordered by RealityKit as Unity would order them by distance.
    @Test
    func testOneQueueKeepsTheMeshOnOneModelEntity() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let head = Self.headModelEntities(in: entity)
        #expect(head.count == 1)
        #expect(head.first?.components[GLTFMaterialSlotsComponent.self]?.materialIndices == [2, Self.opaqueEye, Self.blendedEye])
        #expect(!(head.first?.components.has(ModelSortGroupComponent.self) ?? true))
    }

    /// Blended parts at different queues draw from model entities of their own,
    /// sorted in queue order, while the rest of the mesh keeps its entity.
    @Test
    func testDifferentQueuesSplitTheBlendedPartsIntoSortedEntities() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let modified = try TestSupport.modifiedSeedSanMaterial(name: "queue-split", index: Self.opaqueEye) { material in
            material["alphaMode"] = "BLEND"
            var extensions = material.object("extensions") ?? [:]
            var mtoon = extensions.object("VRMC_materials_mtoon") ?? [:]
            mtoon["renderQueueOffsetNumber"] = -1
            extensions["VRMC_materials_mtoon"] = .object(mtoon)
            material["extensions"] = .object(extensions)
        }
        let entity = try await VRMEntityLoader(withData: modified).loadEntity()
        let head = Self.headModelEntities(in: entity)
        #expect(head.count == 3)

        func sortOrder(ofMaterial materialIndex: Int) throws -> ModelSortGroupComponent {
            let modelEntity = try #require(head.first {
                $0.components[GLTFMaterialSlotsComponent.self]?.materialIndices == [materialIndex]
            })
            return try #require(modelEntity.components[ModelSortGroupComponent.self])
        }
        let under = try sortOrder(ofMaterial: Self.opaqueEye)
        let over = try sortOrder(ofMaterial: Self.blendedEye)
        #expect(under.group == over.group)
        #expect(under.order < over.order)

        let rest = try #require(head.first { !$0.components.has(ModelSortGroupComponent.self) })
        #expect(rest.components[GLTFMaterialSlotsComponent.self]?.materialIndices == [2])

        // The split entities are the mesh to the runtime: skinned, morphed and
        // bound to their materials like the one they came out of.
        #expect(head.allSatisfy { $0.components.has(BlendShapeWeightsComponent.self) })
        #expect(head.allSatisfy { $0.components.has(GLTFSkinIndexComponent.self) })
        for modelEntity in head {
            for case let materialIndex? in modelEntity.components[GLTFMaterialSlotsComponent.self]?.materialIndices ?? [] {
                #expect(entity.materialStates[materialIndex]?.bindings.contains { $0.modelEntity === modelEntity } == true)
            }
        }
    }

    /// The model entities drawing Seed-san's `head` mesh, the siblings of the one
    /// drawing its blended eye, passes aside.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func headModelEntities(in entity: Entity) -> [ModelEntity] {
        let modelEntities = entity.modelEntitiesInHierarchy.filter {
            !$0.components.has(GLTFMaterialPassComponent.self)
        }
        guard let mesh = modelEntities.first(where: {
            $0.components[GLTFMaterialSlotsComponent.self]?.materialIndices.contains(blendedEye) == true
        })?.parent else { return [] }
        return modelEntities.filter { $0.parent === mesh }
    }
}
#endif
