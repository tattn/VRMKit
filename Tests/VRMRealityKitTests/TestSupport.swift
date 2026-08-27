#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Shared fixtures and helpers for the VRMRealityKit test target.
enum TestSupport {
    /// Loads one of the bundled glTF sample assets through the generic loader.
    /// Reading it from its URL is what exercises external-resource resolution.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @MainActor
    static func loadEntity(_ asset: GLTFSampleAsset) async throws -> GLTFEntity {
        try await GLTFEntityLoader(withURL: asset.url).loadEntity()
    }

    /// Loads a bundled glTF sample asset with its JSON rewritten in memory, so a
    /// test can feed the loader an unusual or malformed variant of a fixture
    /// without shipping one.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @MainActor
    static func loader(_ asset: GLTFSampleAsset,
                       rewritingJSON modify: (inout [String: JSONValue]) throws -> Void) throws -> GLTFEntityLoader {
        try GLTFEntityLoader(withData: asset.rewritingJSON(modify), rootDirectory: asset.rootDirectory)
    }

    /// False on visionOS and Mac Catalyst, which bundle no Metal library, so
    /// MToon falls back to Unlit approximations with no outline pass.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @MainActor
    static var isMToonRenderingAvailable: Bool {
        MToonShaderLibraryLoader.resourceName != nil
    }

    /// The default chain with MToon outlines disabled, for tests that inspect
    /// materials without outline siblings in the way.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @MainActor
    static var noOutlineShaders: [any GLTFMaterialShader] {
        [MToonShader(outlinePass: .never)]
    }

    /// The bundled Seed-san VRM 1.0 fixture.
    static var seedSanData: Data { VRMSampleAsset.seedSan.data }

    /// The bundled AliciaSolid VRM 0.x fixture. The VRM 0.x loading paths need
    /// a 0.x model; Seed-san is 1.0.
    static var aliciaSolidData: Data { VRMSampleAsset.aliciaSolid.data }

    /// Rewrites the fixture's glTF JSON in memory. Loaders accept the returned
    /// data directly, so no temporary files are written. `name` identifies the
    /// variant in failure messages.
    static func modifiedSeedSanData(name: String,
                                    modify: (inout [String: JSONValue]) throws -> Void) throws -> Data {
        do {
            return try VRMSampleAsset.seedSan.rewritingJSON(modify)
        } catch let error as GLBRewriter.Error {
            throw VRMError.dataInconsistent("Invalid Seed-san fixture data for '\(name)': \(error)")
        }
    }

    /// Rewrites the VRM 0.x fixture's glTF JSON in memory.
    static func modifiedAliciaSolidData(name: String,
                                        modify: (inout [String: JSONValue]) throws -> Void) throws -> Data {
        do {
            return try VRMSampleAsset.aliciaSolid.rewritingJSON(modify)
        } catch let error as GLBRewriter.Error {
            throw VRMError.dataInconsistent("Invalid AliciaSolid fixture data for '\(name)': \(error)")
        }
    }

    /// Rewrites a single glTF material of the fixture. Wraps the repeated
    /// unwrap/mutate/write-back dance the material tests all need.
    static func modifiedSeedSanMaterial(name: String,
                                        index: Int = 0,
                                        modify: (inout [String: JSONValue]) throws -> Void) throws -> Data {
        try modifiedSeedSanData(name: name) { json in
            var materials = json.objects("materials")
            guard materials.indices.contains(index) else {
                throw VRMError.dataInconsistent("Missing Seed-san material \(index) for fixture '\(name)'")
            }
            try modify(&materials[index])
            json["materials"] = .objects(materials)
        }
    }

    /// Rewrites a material's `VRMC_materials_mtoon` extension.
    static func modifiedSeedSanMToonExtension(name: String,
                                              index: Int = 0,
                                              modify: (inout [String: JSONValue]) throws -> Void) throws -> Data {
        try modifiedSeedSanMaterial(name: name, index: index) { material in
            guard var extensions = material.object("extensions"),
                  var mtoon = extensions.object("VRMC_materials_mtoon") else {
                throw VRMError.dataInconsistent("Missing Seed-san MToon extension for fixture '\(name)'")
            }
            try modify(&mtoon)
            extensions["VRMC_materials_mtoon"] = .object(mtoon)
            material["extensions"] = .object(extensions)
        }
    }

    /// Rewrites the fixture's `VRMC_vrm` preset expressions.
    static func modifiedSeedSanExpressions(name: String,
                                           modify: (inout [String: JSONValue]) throws -> Void) throws -> Data {
        try modifiedSeedSanData(name: name) { json in
            try modifyExpressionPresets(in: &json, modify)
        }
    }

    /// The unwrap/mutate/write-back dance for `extensions.VRMC_vrm.expressions.preset`.
    static func modifyExpressionPresets(in json: inout [String: JSONValue],
                                        _ modify: (inout [String: JSONValue]) throws -> Void) throws {
        guard var extensions = json.object("extensions"),
              var vrm = extensions.object("VRMC_vrm"),
              var expressions = vrm.object("expressions"),
              var preset = expressions.object("preset") else {
            throw VRMError.dataInconsistent("Missing Seed-san expression fixture data")
        }
        try modify(&preset)
        expressions["preset"] = .object(preset)
        vrm["expressions"] = .object(expressions)
        extensions["VRMC_vrm"] = .object(vrm)
        json["extensions"] = .object(extensions)
    }

    /// The MToon shader sources concatenated, read once per test process.
    /// They are repository sources, not bundle resources: the shaders are
    /// compiled offline into the bundled metallibs.
    static let mtoonShaderSource: String = {
        let shaders = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VRMRealityKit/Shaders")
        return ["MToonCore.h", "MToon.metal"]
            .compactMap { try? String(contentsOf: shaders.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }()

    static let expectedCustomMaterialMessage: Comment =
        "Expected default MToon rendering to load a CustomMaterial. Run scripts/build-mtoon-metallibs.sh and verify the package resources."

    @MainActor
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    static func modelEntities(in root: Entity) -> [ModelEntity] {
        root.modelEntitiesInHierarchy
    }

    /// The skeletal pose of everything `root` draws, as the one value that says
    /// whether the model moved at all.
    @MainActor
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    static func jointRotations(in root: Entity) -> [SIMD4<Float>] {
        modelEntities(in: root).flatMap { modelEntity in
            modelEntity.components[SkeletalPosesComponent.self]?.poses.default?
                .jointTransforms.map(\.rotation.vector) ?? []
        }
    }

    /// Whether `entity` hangs under `ancestor`, i.e. whether it is part of that
    /// entity graph at all.
    @MainActor
    static func isDescendant(_ entity: Entity, of ancestor: Entity) -> Bool {
        var current: Entity? = entity
        while let entity = current {
            if entity === ancestor { return true }
            current = entity.parent
        }
        return false
    }

#if !os(visionOS)
    /// Whether any model entity in the hierarchy renders with a CustomMaterial.
    /// visionOS has no `CustomMaterial`, so this only exists where MToon does.
    @MainActor
    @available(iOS 18.0, macOS 15.0, *)
    static func hasCustomMaterial(in root: Entity) -> Bool {
        modelEntities(in: root)
            .flatMap { $0.components[ModelComponent.self]?.materials ?? [] }
            .contains { $0 is CustomMaterial }
    }
#endif

    /// Whether any of the entity's materials carries MToon runtime state.
    @MainActor
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    static func hasMToonParameters(in vrmEntity: VRMEntity) -> Bool {
        materialIndexes(in: vrmEntity).contains { vrmEntity.mtoonParameters(forMaterialIndex: $0) != nil }
    }

    /// Every glTF material index rendered by the hierarchy, in ascending order.
    @MainActor
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    static func materialIndexes(in root: Entity) -> [Int] {
        Set(modelEntities(in: root).compactMap { $0.components[GLTFMaterialIndexComponent.self]?.materialIndex })
            .sorted()
    }

    /// Every primitive of the hierarchy a first-person camera cuts, with what it
    /// draws in either mode.
    @MainActor
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    static func firstPersonCuts(in root: Entity) -> [(entity: Entity, component: FirstPersonMeshComponent)] {
        var cuts: [(Entity, FirstPersonMeshComponent)] = []
        var stack = [root]
        while let entity = stack.popLast() {
            stack.append(contentsOf: entity.children)
            if let component = entity.components[FirstPersonMeshComponent.self] {
                cuts.append((entity, component))
            }
        }
        return cuts
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    static func triangleIndexCount(of mesh: MeshResource) -> Int {
        mesh.contents.models.reduce(0) { count, model in
            count + model.parts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) }
        }
    }

    /// What the primitive under `entity` is drawing now.
    @MainActor
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    static func drawnTriangleIndexCount(of entity: Entity) -> Int {
        modelEntities(in: entity)
            .compactMap { $0.components[ModelComponent.self]?.mesh }
            .map(triangleIndexCount)
            .max() ?? 0
    }

#if !os(visionOS)
    static func isTransparent(_ blending: CustomMaterial.Blending) -> Bool {
        if case .transparent = blending {
            return true
        }
        return false
    }

    static func isOpaque(_ blending: CustomMaterial.Blending) -> Bool {
        if case .opaque = blending {
            return true
        }
        return false
    }
#endif

}
#endif
