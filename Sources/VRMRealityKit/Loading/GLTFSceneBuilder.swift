#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import Metal
import VRMKit
import VRMKitRuntime

/// Builds one scene of a glTF document into one RealityKit entity graph.
///
/// A builder belongs to the one load that made it and is dropped with it, while what the
/// document resolves to whichever load asks lives in ``GLTFResourceCache``.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
final class GLTFSceneBuilder {
    let resources: GLTFResourceCache
    /// Made by the loader, so a VRM load builds into a ``VRMEntity``.
    let root: GLTFEntity
    /// Accessors expanded for this load, shared by the primitives reading the same one.
    let accessors: PackedAccessorCache
    /// Resolved once per load: what it reads off the materials and skins does not change
    /// while one runs.
    var sceneIndex: Int { root.sceneIndex }
    var document: GLTFDocument { resources.document }
    var gltf: GLTF { resources.gltf }

    var prepared = GLTFPreparedResources()

    /// Where one load's time goes. The loader logs it: a slow load is one of these, and
    /// which one decides what to fix.
    struct Timings {
        /// The prepare pass: vertex decoding and its derived data, off the actor.
        var prepareGeometry: Duration = .zero
        /// The prepare pass: image decoding and the texture uploads, off the actor.
        var prepareTextures: Duration = .zero
        /// The upload part of ``prepareTextures``: what RealityKit spends making the
        /// texture resources once the images are decoded.
        var textureUploads: Duration = .zero
        /// Deciding which MASK materials discard nothing, off the actor once both passes are done.
        var cutoutCoverage: Duration = .zero
        /// Textures the build had to make on the actor, for a material asking for one the
        /// prepare pass did not foresee.
        var textureResources: Duration = .zero
        var textureResourceCount = 0
        /// Shading only: the textures a material makes on the way are counted above.
        var materials: Duration = .zero
        var materialCount = 0
        var meshResources: Duration = .zero
        var meshResourceCount = 0
    }
    private(set) var timings = Timings()

    /// The scene's entities, by glTF node index.
    private(set) var nodes: [Entity?]

    /// One mesh entity of the scene, and the node that draws it: VRM annotates first
    /// person per node, and glTF lets two nodes draw one mesh.
    struct SceneMesh {
        let nodeIndex: Int
        let entity: Entity
    }

    /// glTF mesh index → the entities of this scene built from it, one per node.
    private var sceneMeshes: [Int: [SceneMesh]] = [:]
    /// Skin index → this scene's joints in the order RealityKit's skeleton uses.
    private var jointEntitiesBySkin: [Int: [Entity]] = [:]
    /// What the built-in path makes of a material, while the shader chain decorates it.
    private var standardMaterialCache: [Int: Material] = [:]
    /// The sort group the blended parts of the whole model draw in, by render queue.
    private let renderQueueSortGroup = ModelSortGroup()
    private var cachedModelRenderQueueCount: Int?

    init(resources: GLTFResourceCache, root: GLTFEntity) {
        self.resources = resources
        self.root = root
        self.accessors = PackedAccessorCache(document: resources.document)
        self.nodes = Array(repeating: nil, count: resources.gltf.nodes.count)
    }

    struct BuiltScene {
        let nodes: [Entity?]
        let meshes: [Int: [SceneMesh]]
    }

    /// Checks the required extensions, the node graph, the skins and the scene's roots,
    /// before any vertex is read.
    func validateDocument() throws {
        try validateRequiredExtensions()
        let scene = try gltf.load(\.scenes, at: sceneIndex)
        try resources.nodeHierarchy().validateSceneRoots(scene.nodes ?? [], sceneIndex: sceneIndex)
    }

    /// Conditions the vertex data and the images the build draws with, off the actor the
    /// entity graph is built on.
    func prepare() async throws {
        // Vertex decoding is CPU-bound and the texture uploads wait on the GPU, so the
        // two passes overlap rather than queue.
        async let geometry: Void = prepareGeometryPass()
        async let textures: Void = prepareTexturePass()
        _ = try await (geometry, textures)
        try Task.checkCancellation()
        // Reads the decoded geometry against the decoded images, so it follows both.
        let coverageStarted = ContinuousClock.now
        try await prepareCutoutCoverage()
        timings.cutoutCoverage = ContinuousClock.now - coverageStarted
    }

    private func prepareGeometryPass() async throws {
        let started = ContinuousClock.now
        try await prepareGeometry()
        timings.prepareGeometry = ContinuousClock.now - started
    }

    private func prepareTexturePass() async throws {
        let started = ContinuousClock.now
        try await prepareTextures()
        let uploadsStarted = ContinuousClock.now
        try await makeTextureResources()
        timings.textureUploads = ContinuousClock.now - uploadsStarted
        timings.prepareTextures = ContinuousClock.now - started
    }

    func build() throws -> BuiltScene {
        let gltfScene = try gltf.load(\.scenes, at: sceneIndex)
        for node in gltfScene.nodes ?? [] {
            root.addChild(try self.node(withNodeIndex: node))
        }
        root.setNodeEntities(nodes)
        return BuiltScene(nodes: nodes, meshes: sceneMeshes)
    }

    /// Fails the load when the file requires an extension this renderer does not
    /// implement, or leans on one past what is implemented of it.
    private func validateRequiredExtensions() throws {
        let supported = resources.supportedRequiredExtensions
        if let unsupported = gltf.extensionsRequired.first(where: { !supported.contains($0) }) {
            throw VRMError._notSupported("this glTF requires the \(unsupported) extension")
        }
        if resources.enforcesRequiredExtension(GLTFExtension.textureTransform.rawValue) {
            try validateTextureTransformsAreRenderable()
        }
        try resources.profile.validateRequiredExtensionsAreRenderable(of: gltf)
    }

    /// RealityKit gives a material one UV transform and its mesh one UV set, so an asset
    /// merely using `KHR_texture_transform` renders through the first UV-accessed texture's
    /// set and transform, while one that requires it is rejected.
    private func validateTextureTransformsAreRenderable() throws {
        for (index, gltfMaterial) in gltf.materials.enumerated() {
            let textures = GLTFAssetReader.sampledTextures(of: gltfMaterial)
            if let conflict = textures.textureTransformConflict(selectedTexCoord: selectedTexCoord(withMaterialIndex: index)) {
                throw VRMError._notSupported(
                    "this glTF requires KHR_texture_transform, and material \(index) \(conflict), which this renderer cannot draw"
                )
            }
        }
    }

    func node(withNodeIndex index: Int) throws -> Entity {
        if let cache = try loadCached(nodes, at: index, of: "node") { return cache }

        let entity = Entity()
        // A skinned mesh may sit below one of its own joints, so publish the entity before
        // its subtree exists to end that recursion.
        nodes[index] = entity
        do {
            try build(entity, forNodeAt: index)
        } catch {
            nodes[index] = nil
            throw error
        }
        return entity
    }

    private func build(_ entity: Entity, forNodeAt index: Int) throws {
        let gltfNode = try gltf.load(\.nodes, at: index)
        entity.name = gltfNode.name ?? "node_\(index)"
        entity.components.set(GLTFNodeComponent(nodeIndex: index))
        entity.transform = gltfNode.localTransform

        if let cameraIndex = gltfNode.camera {
            try applyCamera(withCameraIndex: cameraIndex, to: entity)
        }

        if let meshIndex = gltfNode.mesh {
            let meshEntity = try mesh(withMeshIndex: meshIndex, skinIndex: gltfNode.skin, nodeIndex: index)
            entity.addChild(meshEntity)
            let modelEntities = meshEntity.modelEntitiesInHierarchy
            let targetCount = try morphTargetCount(ofMeshAt: meshIndex)
            if let weights = try resources.reader().initialMorphWeights(of: gltfNode, meshIndex: meshIndex),
               weights.contains(where: { $0 != 0 }) {
                for modelEntity in modelEntities {
                    modelEntity.deformedMesh?.setBlendShapeWeights(weights)
                }
            }
            root.registerMorphBindings(forNodeAt: index,
                                       modelEntities: modelEntities,
                                       targetCount: targetCount)
        }

        for child in gltfNode.children ?? [] {
            entity.addChild(try node(withNodeIndex: child))
        }
    }

    /// The number of morph targets the mesh at `index` renders with.
    func morphTargetCount(ofMeshAt index: Int) throws -> Int {
        try resources.reader().morphTargetCount(ofMeshAt: index)
    }

    private func applyCamera(withCameraIndex index: Int, to entity: Entity) throws {
        let gltfCamera = try gltf.load(\.cameras, at: index)
        switch gltfCamera.type {
        case .perspective:
            let perspective = try gltfCamera.perspective ??? .keyNotFound("perspective")
            let fovDegrees: Float
            let fovOrientation: CameraFieldOfViewOrientation
            if let aspectRatio = perspective.aspectRatio, aspectRatio > 0 {
                let yFov = perspective.yfov
                let xFov = 2 * atan(tan(yFov * 0.5) * aspectRatio)
                fovDegrees = xFov * 180 / .pi
                fovOrientation = .horizontal
            } else {
                fovDegrees = perspective.yfov * 180 / .pi
                fovOrientation = .vertical
            }
            var component = PerspectiveCameraComponent(near: perspective.znear,
                                                       far: perspective.zfar ?? .infinity,
                                                       fieldOfViewInDegrees: fovDegrees)
            component.fieldOfViewOrientation = fovOrientation
            entity.components.set(component)
        case .orthographic:
            let orthographic = try gltfCamera.orthographic ??? .keyNotFound("orthographic")
            var component = OrthographicCameraComponent()
            component.near = orthographic.znear
            component.far = orthographic.zfar
            component.scale = orthographic.ymag
            component.scaleDirection = .vertical
            entity.components.set(component)
        }
    }

    /// The entity one node renders a glTF mesh through, one per call.
    func mesh(withMeshIndex index: Int, skinIndex: Int?, nodeIndex: Int) throws -> Entity {
        let key = try resources.reader().meshKey(forNodeAt: nodeIndex, meshIndex: index, skinIndex: skinIndex)
        // Built once per template and cloned per node: the clones share the vertex data
        // and each deform a mesh of their own with their own pose and weights.
        let meshEntity = try meshTemplate(key, nodeIndex: nodeIndex).clone(recursive: true)
        try instantiateDeformedMeshes(in: meshEntity)
        try registerSkinBindings(in: meshEntity)
        registerMaterialBindings(in: meshEntity)
        sceneMeshes[index, default: []].append(.init(nodeIndex: nodeIndex, entity: meshEntity))
        return meshEntity
    }

    /// The clone source for one mesh as one node draws it, which never joins a scene.
    private func meshTemplate(_ key: GLTFAssetReader.MeshKey, nodeIndex: Int) throws -> Entity {
        if let cache = resources.meshTemplates[key] { return cache }
        let template = try makeMeshEntity(key, nodeIndex: nodeIndex)
        resources.meshTemplates[key] = template
        return template
    }

    private func makeMeshEntity(_ key: GLTFAssetReader.MeshKey, nodeIndex: Int) throws -> Entity {
        let built = try assetMesh(key, nodeIndex: nodeIndex)
        for warning in built.warnings {
            resources.logOnce(warning.key, warning.message)
        }
        let mesh = built.mesh
        let meshEntity = Entity()
        meshEntity.name = mesh.name
        guard !mesh.materialIndices.isEmpty else { return meshEntity }

        let primitives = try mesh.materialIndices.map { materialIndex in
            SlotMaterial(materialIndex: materialIndex,
                         shaded: try materialIndex.map { try shadedMaterial(withMaterialIndex: $0) }
                             ?? GLTFShadedMaterial(material: Self.defaultMaterial()))
        }
        let skeleton = try mesh.skinIndex.map { try skeleton(withSkinIndex: $0) }
        // One vertex array for the whole mesh: every entity drawing it, render passes
        // and render-queue groups alike, deforms from the same source and draws its own
        // slots of it, so the vertices are skinned once per frame, not once per entity.
        let started = ContinuousClock.now
        let source = try GLTFMeshSource(geometry: mesh.geometry, skeleton: skeleton, context: try GLTFDeformationContext.shared())
        timings.meshResources += ContinuousClock.now - started
        timings.meshResourceCount += 1
        let skinIndex = mesh.skinIndex

        // Each distinct pass of the mesh's materials becomes one sibling model entity
        // drawing every slot whose material has the pass, in first-appearance order.
        var passNames: [String] = []
        for primitive in primitives {
            for pass in primitive.shaded.additionalPasses where !passNames.contains(pass.name) {
                passNames.append(pass.name)
            }
        }
        for name in passNames {
            var drawing: [SlotDrawing] = []
            var passes: [GLTFShadedMaterial.Pass] = []
            for (slot, primitive) in primitives.enumerated() {
                guard let pass = primitive.shaded.additionalPasses.first(where: { $0.name == name }) else { continue }
                drawing.append(SlotDrawing(slot: slot, material: pass.material, isInitiallyVisible: pass.isInitiallyEnabled))
                passes.append(pass)
            }
            let passEntity = try makeModelEntity(name: "\(meshEntity.name)_\(name)",
                                                 source: source,
                                                 primitives: primitives,
                                                 drawing: drawing,
                                                 skinIndex: skinIndex)
            passEntity.components.set(GLTFMaterialPassComponent(name: name))
            grantBoundsBudget(to: passEntity, passes: passes)
            // The passes go on before the main model entity, keeping their draw order.
            meshEntity.addChild(passEntity)
        }

        // RealityKit orders blended parts back to front by their bounds, which flips
        // parts an author stacked on purpose once the view tilts, such as an eye highlight
        // a few millimetres over its iris or bangs blended over the face of another mesh.
        // When the model's materials ask for different render queues, its blended parts
        // draw from entities of their own, one per queue, in one sort group for the
        // whole model that keeps the queue order. Parts of one queue are still ordered
        // back to front within it.
        let renderQueues = Set(primitives.compactMap(\.shaded.renderQueue)).sorted()
        var groups: [(queue: Int?, slots: [Int])] = [(nil, Array(primitives.indices))]
        var sortGroup: ModelSortGroup?
        if !renderQueues.isEmpty, try modelRenderQueueCount() > 1 {
            groups = (renderQueues.map(Optional.some) + [nil]).map { queue in
                (queue, primitives.indices.filter { primitives[$0].shaded.renderQueue == queue })
            }
            sortGroup = renderQueueSortGroup
        }
        for (queue, slots) in groups where !slots.isEmpty {
            let modelEntity = try makeModelEntity(
                name: "\(meshEntity.name)_model\(queue.map { "_\($0)" } ?? "")",
                source: source,
                primitives: primitives,
                drawing: slots.map {
                    SlotDrawing(slot: $0, material: primitives[$0].shaded.material, isInitiallyVisible: true)
                },
                skinIndex: skinIndex)
            if let queue, let sortGroup {
                modelEntity.components.set(ModelSortGroupComponent(group: sortGroup, order: Int32(queue)))
            }
            meshEntity.addChild(modelEntity)
        }
        return meshEntity
    }

    /// The primitives a mesh is built from, as the profile reads them off the document.
    func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] {
        resources.profile.resolvedPrimitives(of: mesh)
    }

    /// One slot of a mesh and the material it is shaded with.
    private struct SlotMaterial {
        let materialIndex: Int?
        let shaded: GLTFShadedMaterial
    }

    /// How one model entity draws one slot of its mesh.
    private struct SlotDrawing {
        let slot: Int
        let material: Material
        let isInitiallyVisible: Bool
    }

    /// One model entity drawing the slots of `source` that `drawing` names, each
    /// addressing its material by its position in `drawing`.
    private func makeModelEntity(name: String,
                                 source: GLTFMeshSource,
                                 primitives: [SlotMaterial],
                                 drawing: [SlotDrawing],
                                 skinIndex: Int?) throws -> ModelEntity {
        let deformedMesh = try GLTFDeformedMesh(source: source, drawnSlots: drawing.map(\.slot))
        let entity = ModelEntity(mesh: deformedMesh.meshResource, materials: drawing.map(\.material))
        entity.name = name
        entity.components.set(GLTFMaterialSlotsComponent(materialIndices: drawing.map { primitives[$0.slot].materialIndex }))
        if let skinIndex, source.skin != nil {
            // The binding is registered per clone, once its joints exist.
            entity.components.set(GLTFSkinIndexComponent(skinIndex: skinIndex))
            // The parts carry the rest bounds, and a posed joint can carry its vertices
            // outside them; the mesh's own radius covers a pose of the body.
            if var component = entity.components[ModelComponent.self] {
                component.boundsMargin = source.geometry.bounds.boundingRadius
                entity.components.set(component)
            }
        }
        // The component ships with the OS 27 SDKs, which bring Swift 6.4; older SDKs have no occlusion culling.
        #if compiler(>=6.4)
        if source.isDeformable, #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            // RealityKit only sees the rest bounds of vertices deformed here on the GPU, so its
            // occlusion culling drops a posed mesh whole, such as a turned face judged to be
            // behind its own hair, even with the bounds margin.
            entity.components.set(OcclusionCullingComponent(isEnabled: false))
        }
        #endif
        entity.components.set(GLTFMergedMeshComponent(initiallyVisibleSlots: drawing.map(\.isInitiallyVisible)))
        entity.setDeformedMesh(deformedMesh)
        return entity
    }

    /// Gives every model entity cloned off a template a deformed mesh of its own, drawn
    /// from the template's vertex data, so each node and each load poses its own.
    private func instantiateDeformedMeshes(in meshRoot: Entity) throws {
        for modelEntity in meshRoot.modelEntitiesInHierarchy {
            guard let template = modelEntity.deformedMesh else { continue }
            let own = try GLTFDeformedMesh(source: template.source, drawnSlots: template.drawnSlots)
            modelEntity.setDeformedMesh(own)
            root.registerDeformedMesh(own)
        }
    }

    /// Widens the bounding box RealityKit culls `passEntity` by, so a geometry modifier
    /// pushing vertices outward is not culled while on screen, and tells each slot's
    /// modifier how much room it got.
    private func grantBoundsBudget(to passEntity: ModelEntity,
                                   passes: [GLTFShadedMaterial.Pass]) {
        guard passes.contains(where: { $0.applyBoundsBudget != nil }),
              let geometry = passEntity.gltfMeshGeometry,
              var component = passEntity.components[ModelComponent.self] else { return }
        // The budget covers the whole merged mesh, hidden slots included, so a slot
        // shown later still fits it.
        let budget = geometry.bounds.boundingRadius
        component.boundsMargin = max(component.boundsMargin, budget)
        for (slot, pass) in passes.enumerated() {
            guard let applyBudget = pass.applyBoundsBudget,
                  component.materials.indices.contains(slot) else { continue }
            component.materials[slot] = applyBudget(component.materials[slot], budget)
        }
        passEntity.components.set(component)
    }

    /// The UV set the meshes drawing the material at `index` carry. A shader sampling any
    /// other set renders through this one.
    func selectedTexCoord(withMaterialIndex index: Int) -> Int {
        guard let material = try? gltf.load(\.materials, at: index) else { return 0 }
        return GLTFAssetReader.resolvedTexCoord(of: material).selected
    }

    /// The main material of ``shadedMaterial(withMaterialIndex:)``.
    func material(withMaterialIndex index: Int) throws -> Material {
        try shadedMaterial(withMaterialIndex: index).material
    }

    /// The single place what a material renders as is decided.
    func shadedMaterial(withMaterialIndex index: Int) throws -> GLTFShadedMaterial {
        if let cached = try loadCached(resources.materials, at: index, of: "material") { return cached }
        defer { standardMaterialCache.removeValue(forKey: index) }
        // Resolving is not shading: an index the document does not hold fails the load
        // rather than reaching a fallback.
        let context = try makeMaterialShaderContext(withMaterialIndex: index)
        let started = ContinuousClock.now
        let texturesBefore = timings.textureResources
        let shaded: GLTFShadedMaterial
        do {
            shaded = try shadeMaterial(for: context)
        } catch {
            guard let fallback = resources.materialFallback?(context, error) else { throw error }
            shaded = fallback
        }
        timings.materials += (ContinuousClock.now - started) - (timings.textureResources - texturesBefore)
        timings.materialCount += 1
        if resources.materials.indices.contains(index) {
            resources.materials[index] = shaded
        }
        return shaded
    }

    /// What the shader chain makes of an already resolved material, falling back to the
    /// built-in Unlit / PBR path when no shader claims it.
    private func shadeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial {
        for shader in resources.shaders {
            if let shaded = try shader.makeMaterial(for: context) { return shaded }
        }
        return GLTFShadedMaterial(material: try standardMaterial(for: context),
                                  renderQueue: try context.resolvedRenderQueue())
    }

    func makeMaterialShaderContext(withMaterialIndex index: Int) throws -> GLTFMaterialShaderContext {
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
        return GLTFMaterialShaderContext(builder: self,
                                         materialIndex: index,
                                         material: gltfMaterial,
                                         vrm0MaterialProperty: materialProperty)
    }

    /// The built-in Unlit / PBR path of the glTF core specification, rendering every
    /// material the shader chain leaves unclaimed. Shaders reach it through
    /// ``GLTFMaterialShaderContext/standardMaterial()`` to decorate its result.
    func standardMaterial(for context: GLTFMaterialShaderContext) throws -> Material {
        if let cached = standardMaterialCache[context.materialIndex] { return cached }
        let material = try makeStandardMaterial(for: context)
        standardMaterialCache[context.materialIndex] = material
        return material
    }

    private func makeStandardMaterial(for context: GLTFMaterialShaderContext) throws -> Material {
        let index = context.materialIndex
        let gltfMaterial = context.material
        let materialProperty = context.vrm0MaterialProperty
        let shaderName = materialProperty?.shader.lowercased()
        // Unreadable MToon is still MToon, so it takes the same Unlit approximation.
        let isMToon = try mtoonResolution(withMaterialIndex: index).isMToon
        let isUnlit = shaderName?.contains("unlit") == true || gltfMaterial.extensions?.materialsUnlit != nil
        // MToon and Unlit variants are not PBR, so both render through UnlitMaterial.
        let useUnlit = isMToon || isUnlit
        let resolvedAlphaMode = context.resolvedAlphaMode
        let tint = gltfMaterial.pbrMetallicRoughness
            .map { resources.outputColorSpace.color($0.baseColorFactor) } ?? .white

        if useUnlit {
            // RealityKit's tone mapping visibly darkens flat art, so opt out of it where it applies.
            var material = UnlitMaterial(applyPostProcessToneMap: !resources.compensatesToneMapping)
            if let pbr = gltfMaterial.pbrMetallicRoughness,
               let baseTexture = pbr.baseColorTexture {
                let textureParam = try materialTexture(withTextureIndex: baseTexture.index, semantic: .color)
                material.color = .init(tint: tint, texture: textureParam)
            } else {
                material.color = .init(tint: tint)
            }
            applyAlphaMode(resolvedAlphaMode, alphaCutoff: gltfMaterial.alphaCutoff, to: &material)
            if gltfMaterial.doubleSided {
                material.faceCulling = .none
            }
            material.textureCoordinateTransform = standardTextureTransform(withMaterialIndex: index, of: gltfMaterial)
            return material
        }

        var material = PhysicallyBasedMaterial()
        if let pbr = gltfMaterial.pbrMetallicRoughness {
            if let baseTexture = pbr.baseColorTexture {
                let textureParam = try materialTexture(withTextureIndex: baseTexture.index, semantic: .color)
                material.baseColor = .init(tint: tint, texture: textureParam)
            } else {
                material.baseColor = .init(tint: tint)
            }

            if let metallicTexture = pbr.metallicRoughnessTexture {
                // glTF multiplies the sampled channel by its factor, as RealityKit's
                // texture-plus-scale pair does.
                let textures = try metallicRoughnessTextures(withTextureIndex: metallicTexture.index)
                material.metallic = .init(scale: pbr.metallicFactor, texture: textures.metal)
                material.roughness = .init(scale: pbr.roughnessFactor, texture: textures.rough)
            } else {
                material.metallic = .init(floatLiteral: pbr.metallicFactor)
                material.roughness = .init(floatLiteral: pbr.roughnessFactor)
            }
        } else {
            material.baseColor = .init(tint: tint)
            material.metallic = .init(floatLiteral: 1.0)
            material.roughness = .init(floatLiteral: 1.0)
        }

        if let normalTexture = gltfMaterial.normalTexture {
            material.normal.texture = try normalTextureParameter(normalTexture)
        }

        if let occlusionTexture = gltfMaterial.occlusionTexture {
            material.ambientOcclusion.texture = try occlusionTextureParameter(occlusionTexture)
        }

        let emissiveFactor = gltfMaterial.emissiveFactor
        let emissiveTint = resources.outputColorSpace.color(SIMD4<Float>(emissiveFactor, 1))
        let hasEmissiveTint = emissiveFactor != .zero
        if let emissiveTexture = gltfMaterial.emissiveTexture {
            let textureParam = try materialTexture(withTextureIndex: emissiveTexture.index, semantic: .color)
            material.emissiveColor = .init(color: emissiveTint,
                                           texture: textureParam)
        } else if hasEmissiveTint {
            material.emissiveColor = .init(color: emissiveTint)
        }

        applyAlphaMode(resolvedAlphaMode, alphaCutoff: gltfMaterial.alphaCutoff, to: &material)
        if gltfMaterial.doubleSided {
            material.faceCulling = .none
        }
        material.textureCoordinateTransform = standardTextureTransform(withMaterialIndex: index, of: gltfMaterial)

        return material
    }

    /// The `KHR_texture_transform` a material renders with. RealityKit gives a material
    /// one UV transform, so the first UV-accessed texture's wins.
    func selectedUVTransform(withMaterialIndex index: Int,
                             textures: [GLTFSampledTexture]) -> GLTFUVTransform {
        let selected = textures.first?.transform ?? GLTFUVTransform()
        if textures.contains(where: { ($0.transform ?? GLTFUVTransform()) != selected }) {
            resources.logOnce("uvTransform-\(index)", """
                Material \(index) has per-texture KHR_texture_transform values; \
                RealityKit applies the first UV-accessed transform to all of its textures.
                """)
        }
        return selected
    }

    /// Converts `KHR_texture_transform` into RealityKit's `textureCoordinateTransform`.
    /// Only the rotation direction mirrors: offset and scale already act from the corner
    /// the extension measures from.
    private func standardTextureTransform(withMaterialIndex index: Int,
                                          of gltfMaterial: GLTF.Material) -> MaterialParameterTypes.TextureCoordinateTransform {
        let transform = selectedUVTransform(withMaterialIndex: index,
                                            textures: GLTFAssetReader.sampledTextures(of: gltfMaterial))
        return MaterialParameterTypes.TextureCoordinateTransform(offset: transform.offset,
                                                                 scale: transform.scale,
                                                                 rotation: -transform.rotation)
    }

    /// What MToon data the material at `index` carries, from the `VRMC_materials_mtoon`
    /// extension or the VRM 0.x material property. The built-in fallback and tangent
    /// generation both read it.
    func mtoonResolution(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor.Resolution {
        if let cached = resources.mtoonResolutionCache[index] {
            return cached
        }
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
        let resolution = MToonMaterialDescriptor.resolve(material: gltfMaterial,
                                                         materialProperty: materialProperty)
        if case .unsupportedVersion(let specVersion) = resolution {
            resources.logOnce("mtoonSpecVersion-\(specVersion)", """
                Material \(index) declares VRMC_materials_mtoon specVersion \(specVersion), which this \
                renderer does not implement, so it renders as an Unlit approximation.
                """)
        }
        resources.mtoonResolutionCache[index] = resolution
        return resolution
    }

    /// The MToon material model describing the material at `index`, or nil when it
    /// carries none this renderer can read.
    func mtoonDescriptor(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor? {
        try mtoonResolution(withMaterialIndex: index).descriptor
    }

    /// The glTF material and, for VRM 0.x, the Unity material property describing it.
    /// Both are array lookups, so neither is cached.
    private func materialSource(withMaterialIndex index: Int) throws -> (GLTF.Material, VRM0.MaterialProperty?) {
        (try gltf.load(\.materials, at: index), resources.profile.vrm0MaterialProperty(atMaterialIndex: index))
    }

    /// A fresh mutable runtime state for the material, made by the material on screen,
    /// so it always describes what is actually drawn.
    func makeAnimatableMaterialState(forMaterialIndex index: Int) -> (any VRMAnimatableMaterialState)? {
        (try? shadedMaterial(withMaterialIndex: index))?.makeAnimatableState?()
    }

    /// How the material at `index` draws: the alpha mode its shader was handed and the render
    /// queue it asked for.
    func materialDrawing(forMaterialIndex index: Int) -> (alphaMode: GLTF.Material.AlphaMode, renderQueue: Int?) {
        ((try? makeMaterialShaderContext(withMaterialIndex: index))?.resolvedAlphaMode ?? .OPAQUE,
         (try? shadedMaterial(withMaterialIndex: index))?.renderQueue)
    }

    /// How many render queues the materials this builder's scene draws with ask for.
    private func modelRenderQueueCount() throws -> Int {
        if let cachedModelRenderQueueCount { return cachedModelRenderQueueCount }
        let queues = try drawnMaterialIndices().compactMap { try shadedMaterial(withMaterialIndex: $0).renderQueue }
        let count = Set(queues).count
        cachedModelRenderQueueCount = count
        return count
    }

    /// The materials this builder's scene draws with.
    func drawnMaterialIndices() throws -> Set<Int> {
        var indices: Set<Int> = []
        for drawn in try drawnMeshes() {
            for primitive in resolvedPrimitives(of: drawn.mesh) {
                if let material = primitive.material { indices.insert(material) }
            }
        }
        return indices
    }

    /// The textures the material at `index` samples: the glTF slots, whatever its
    /// extensions name, read as written so an unmodeled extension counts too, and
    /// whatever the profile names beside the material.
    func textureIndices(ofMaterialAt index: Int) -> Set<Int> {
        guard let material = gltf.materials[safe: index] else { return [] }
        var indices = Set([material.normalTexture?.index,
                           material.occlusionTexture?.index,
                           material.emissiveTexture?.index,
                           material.pbrMetallicRoughness?.baseColorTexture?.index,
                           material.pbrMetallicRoughness?.metallicRoughnessTexture?.index].compactMap { $0 })
        for (_, extensionValue) in material.extensions?.raw ?? [:] {
            for (key, slot) in extensionValue.dictionaryValue where key.hasSuffix("Texture") {
                if let texture = slot.dictionaryValue["index"]?.indexValue { indices.insert(texture) }
            }
        }
        return indices.union(resources.profile.extraTextureIndices(ofMaterialAt: index))
    }

    /// One image's share of the texture prepare pass: the decode, and whatever per-pixel
    /// bakes the materials sampling it ask for.
    private struct TextureWork: Sendable {
        let imageIndex: Int
        var normalScales: Set<Float> = []
        var occlusionStrengths: Set<Float> = []
        var splitsMetallicRoughness = false
    }

    private struct PreparedTexture: @unchecked Sendable {
        let imageIndex: Int
        let image: CGImage
        let normalBakes: [(scale: Float, image: CGImage)]
        let occlusionBakes: [(strength: Float, image: CGImage)]
        let metallicRoughness: (metal: CGImage, rough: CGImage)?
    }

    /// Decodes the texture images and runs their per-pixel bakes off the actor the entity
    /// graph is built on, as ``prepareGeometry()`` does for vertex data.
    ///
    /// Only what the scene draws with is prepared; a texture it misses is decoded during
    /// the build instead.
    func prepareTextures() async throws {
        var work: [Int: TextureWork] = [:]
        func item(forTextureIndex textureIndex: Int) -> Int? {
            guard let source = gltf.textures[safe: textureIndex]?.source else { return nil }
            if work[source] == nil, prepared.images[source] == nil {
                work[source] = TextureWork(imageIndex: source)
            }
            return source
        }
        for materialIndex in try drawnMaterialIndices() {
            guard let material = gltf.materials[safe: materialIndex] else { continue }
            for texture in textureIndices(ofMaterialAt: materialIndex) {
                _ = item(forTextureIndex: texture)
            }
            if let normal = material.normalTexture, normal.scale != 1,
               let image = item(forTextureIndex: normal.index) {
                work[image]?.normalScales.insert(normal.scale)
            }
            if let occlusion = material.occlusionTexture, occlusion.strength != 1,
               let image = item(forTextureIndex: occlusion.index) {
                work[image]?.occlusionStrengths.insert(occlusion.strength)
            }
            if let metallic = material.pbrMetallicRoughness?.metallicRoughnessTexture,
               let image = item(forTextureIndex: metallic.index) {
                work[image]?.splitsMetallicRoughness = true
            }
        }
        guard !work.isEmpty else { return }

        let document = self.document
        let maxTextureDimension = resources.maxTextureDimension
        let decoded = try await withThrowingTaskGroup(of: PreparedTexture.self) { group in
            for item in work.values {
                group.addTask {
                    try Task.checkCancellation()
                    // Before the bakes and the metallic/roughness split read it, so every
                    // texture derived from this image shrinks with it.
                    let image = try Self.clamped(document.image(at: item.imageIndex),
                                                 to: maxTextureDimension)
                    return PreparedTexture(
                        imageIndex: item.imageIndex,
                        image: image,
                        normalBakes: try item.normalScales.map {
                            ($0, try Self.scaledNormalImage(image, scale: $0))
                        },
                        occlusionBakes: try item.occlusionStrengths.map {
                            ($0, try Self.weakenedOcclusionImage(image, strength: $0))
                        },
                        metallicRoughness: item.splitsMetallicRoughness
                            ? try metallicRoughnessImages(from: image)
                            : nil
                    )
                }
            }
            var results: [PreparedTexture] = []
            results.reserveCapacity(work.count)
            for try await result in group {
                results.append(result)
            }
            return results
        }
        for result in decoded {
            prepared.images[result.imageIndex] = result.image
            for bake in result.normalBakes {
                prepared.bakedImages[GLTFBakedImageKey(imageIndex: result.imageIndex,
                                                       factor: bake.scale,
                                                       semantic: .normal)] = bake.image
            }
            for bake in result.occlusionBakes {
                prepared.bakedImages[GLTFBakedImageKey(imageIndex: result.imageIndex,
                                                       factor: bake.strength,
                                                       semantic: .raw)] = bake.image
            }
            if let split = result.metallicRoughness {
                prepared.metallicRoughnessImages[result.imageIndex] = split
            }
        }
    }

    /// The textures the drawn materials read, by image and semantic, as far as the
    /// document tells ahead of shading. A material asking for one not listed here makes
    /// it on the actor; the answer is only wrong by speed.
    private func requestedTextureKeys() throws -> Set<GLTFResourceCache.ImageTextureKey> {
        var keys: Set<GLTFResourceCache.ImageTextureKey> = []
        func request(_ textureIndex: Int, _ semantic: TextureResource.Semantic) {
            guard let imageIndex = try? gltf.imageIndex(ofTextureAt: textureIndex) else { return }
            keys.insert(.init(imageIndex: imageIndex, semantic: semantic))
        }
        for materialIndex in try drawnMaterialIndices() {
            guard let material = gltf.materials[safe: materialIndex] else { continue }
            if let mtoon = try? mtoonDescriptor(withMaterialIndex: materialIndex) {
                for slot in MToonTextureSlot.allCases {
                    if let texture = mtoon.texture(for: slot) { request(texture.index, slot.semantic) }
                }
                continue
            }
            if let base = material.pbrMetallicRoughness?.baseColorTexture { request(base.index, .color) }
            if let emissive = material.emissiveTexture { request(emissive.index, .color) }
            // Scaled normals and weakened occlusion are baked into their own images first.
            if let normal = material.normalTexture, normal.scale == 1 { request(normal.index, .normal) }
            if let occlusion = material.occlusionTexture, occlusion.strength == 1 { request(occlusion.index, .raw) }
        }
        return keys
    }

    private struct TextureUpload: @unchecked Sendable {
        let key: GLTFResourceCache.ImageTextureKey
        let image: CGImage
    }

    private struct UploadedTexture: @unchecked Sendable {
        let key: GLTFResourceCache.ImageTextureKey
        let texture: TextureResource
    }

    /// Makes the textures the build will ask for, all at once and off the actor, so the
    /// build finds them cached: uploaded one at a time on the actor, they are the larger
    /// part of building a textured model.
    private func makeTextureResources() async throws {
        var uploads: [TextureUpload] = []
        for key in try requestedTextureKeys() where resources.textureCache[key] == nil {
            uploads.append(TextureUpload(key: key, image: uploadedImage(try image(withImageIndex: key.imageIndex),
                                                                        semantic: key.semantic)))
        }
        guard !uploads.isEmpty else { return }
        let uploaded = try await withThrowingTaskGroup(of: UploadedTexture.self) { group in
            for upload in uploads {
                group.addTask {
                    try Task.checkCancellation()
                    let texture = try await TextureResource(image: upload.image,
                                                            withName: nil,
                                                            options: .init(semantic: upload.key.semantic))
                    return UploadedTexture(key: upload.key, texture: texture)
                }
            }
            var results: [UploadedTexture] = []
            results.reserveCapacity(uploads.count)
            for try await result in group {
                results.append(result)
            }
            return results
        }
        for result in uploaded {
            resources.textureCache[result.key] = result.texture
        }
    }

    func texture(withTextureIndex index: Int, semantic: TextureResource.Semantic = .color) throws -> TextureResource {
        let key = GLTFResourceCache.ImageTextureKey(imageIndex: try gltf.imageIndex(ofTextureAt: index),
                                                    semantic: semantic)
        if let cache = resources.textureCache[key] { return cache }
        let cgImage = try image(withImageIndex: key.imageIndex)
        let texture = try makeTextureResource(cgImage, semantic: semantic)
        resources.textureCache[key] = texture
        return texture
    }

    private func makeTextureResource(_ image: CGImage, semantic: TextureResource.Semantic) throws -> TextureResource {
        let started = ContinuousClock.now
        defer {
            timings.textureResources += ContinuousClock.now - started
            timings.textureResourceCount += 1
        }
        return try TextureResource(image: uploadedImage(image, semantic: semantic), options: .init(semantic: semantic))
    }

    /// The image RealityKit reads `semantic` from: a color image tagged for the output color space.
    private func uploadedImage(_ image: CGImage, semantic: TextureResource.Semantic) -> CGImage {
        semantic == .color ? resources.outputColorSpace.colorImage(image) : image
    }

    func materialTexture(withTextureIndex index: Int,
                         semantic: TextureResource.Semantic = .color) throws -> MaterialParameters.Texture {
        let texture = try texture(withTextureIndex: index, semantic: semantic)
        let sampler = try sampler(withTextureIndex: index)
        return MaterialParameters.Texture(texture, sampler: sampler)
    }

    func sampler(withTextureIndex index: Int) throws -> MaterialParameters.Texture.Sampler {
        let samplerIndex = try gltf.load(\.textures, at: index).sampler
        if let cache = resources.samplerCache[samplerIndex] {
            return cache
        }
        let descriptor = MTLSamplerDescriptor()
        applySampler(try samplerIndex.map { try gltf.load(\.samplers, at: $0) }, to: descriptor)
        let sampler = MaterialParameters.Texture.Sampler(descriptor)
        resources.samplerCache[samplerIndex] = sampler
        return sampler
    }

    /// The glTF sampler a texture references, or nil when it uses the defaults.
    func gltfSampler(withTextureIndex index: Int) throws -> GLTF.Sampler? {
        guard let samplerIndex = try gltf.load(\.textures, at: index).sampler else { return nil }
        return try gltf.load(\.samplers, at: samplerIndex)
    }

    private func applySampler(_ sampler: GLTF.Sampler?, to descriptor: MTLSamplerDescriptor) {
        descriptor.magFilter = (sampler?.magFilter ?? .LINEAR).metalFilter
        let (min, mip) = (sampler?.minFilter ?? .LINEAR_MIPMAP_LINEAR).metalFilters
        descriptor.minFilter = min
        descriptor.mipFilter = mip
        descriptor.sAddressMode = (sampler?.wrapS ?? .REPEAT).metalAddressMode
        descriptor.tAddressMode = (sampler?.wrapT ?? .REPEAT).metalAddressMode
    }

    /// The decoded image at `index`: what the prepare pass decoded, or a decode on the
    /// spot for one it did not reach. Kept for the rest of the load, since one image may
    /// be read as several textures.
    func image(withImageIndex index: Int) throws -> CGImage {
        if let cache = prepared.images[index] { return cache }
        let image = try Self.clamped(document.image(at: index), to: resources.maxTextureDimension)
        prepared.images[index] = image
        return image
    }

    /// An image no larger than `limit` on its longest side, redrawn at that size when it is.
    ///
    /// Whether a document's textures are oversized is a question about the app's output
    /// resolution rather than about the document, so nothing is resized without a limit.
    nonisolated static func clamped(_ image: @autoclosure () throws -> CGImage, to limit: Int?) rethrows -> CGImage {
        let image = try image()
        guard let limit, limit > 0, max(image.width, image.height) > limit else { return image }
        let scale = Double(limit) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        func context(space: CGColorSpace?, bitmapInfo: UInt32) -> CGContext? {
            guard let space else { return nil }
            return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: space, bitmapInfo: bitmapInfo)
        }
        // Core Graphics draws into no non-premultiplied alpha format, which is how a PNG
        // with alpha decodes, so such an image is redrawn as premultiplied RGBA.
        guard let context = context(space: image.colorSpace, bitmapInfo: image.bitmapInfo.rawValue)
                ?? context(space: CGColorSpace(name: CGColorSpace.sRGB),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              // A failed resize is not worth failing the load over.
              let resized: CGImage = {
                  context.interpolationQuality = .high
                  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                  return context.makeImage()
              }() else { return image }
        return resized
    }

    /// The normal map a material samples, with `normalTexture.scale` applied.
    private func normalTextureParameter(_ info: GLTF.Material.NormalTextureInfo) throws -> MaterialParameters.Texture {
        guard info.scale != 1 else {
            return try materialTexture(withTextureIndex: info.index, semantic: .normal)
        }
        return try bakedTexture(withTextureIndex: info.index,
                                factor: info.scale,
                                semantic: .normal,
                                bake: Self.scaledNormalImage)
    }

    /// The occlusion map a material samples, with `occlusionTexture.strength` applied.
    /// Occlusion is linear data, so `.raw`: `.color` would apply an sRGB conversion.
    private func occlusionTextureParameter(_ info: GLTF.Material.OcclusionTextureInfo) throws -> MaterialParameters.Texture {
        guard info.strength != 1 else {
            return try materialTexture(withTextureIndex: info.index, semantic: .raw)
        }
        return try bakedTexture(withTextureIndex: info.index,
                                factor: info.strength,
                                semantic: .raw,
                                bake: Self.weakenedOcclusionImage)
    }

    /// A texture with one of glTF's scalar factors baked into its pixels: RealityKit's
    /// normal and ambient-occlusion parameters carry no scalar beside the texture.
    private func bakedTexture(withTextureIndex index: Int,
                              factor: Float,
                              semantic: TextureResource.Semantic,
                              bake: (CGImage, Float) throws -> CGImage) throws -> MaterialParameters.Texture {
        let key = GLTFBakedImageKey(imageIndex: try gltf.imageIndex(ofTextureAt: index),
                                    factor: factor,
                                    semantic: semantic)
        let resource: TextureResource
        if let cached = resources.bakedTextureCache[key] {
            resource = cached
        } else {
            // Baked by the prepare pass off-actor, or now for a texture it missed.
            let baked = try prepared.bakedImages[key]
                ?? bake(try image(withImageIndex: key.imageIndex), factor)
            resource = try makeTextureResource(baked, semantic: semantic)
            resources.bakedTextureCache[key] = resource
        }
        return MaterialParameters.Texture(resource, sampler: try sampler(withTextureIndex: index))
    }

    /// glTF scales a sampled normal's x and y by `normalTexture.scale` and renormalizes
    /// it, which the map can carry itself.
    nonisolated static func scaledNormalImage(_ image: CGImage, scale: Float) throws -> CGImage {
        try rewritingPixels(of: image) { pixels, pixelCount in
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let decoded = SIMD3<Float>(Float(pixels[offset]),
                                           Float(pixels[offset + 1]),
                                           Float(pixels[offset + 2])) / 127.5 - 1
                let scaled = SIMD3<Float>(decoded.x * scale, decoded.y * scale, decoded.z)
                let length = simd_length(scaled)
                // An unusable texel keeps the neutral, straight-up normal.
                let normal = length > 1e-6 ? scaled / length : SIMD3<Float>(0, 0, 1)
                let encoded = (normal + 1) * 127.5
                pixels[offset] = UInt8(clamping: Int(encoded.x.rounded()))
                pixels[offset + 1] = UInt8(clamping: Int(encoded.y.rounded()))
                pixels[offset + 2] = UInt8(clamping: Int(encoded.z.rounded()))
            }
        }
    }

    /// glTF blends sampled occlusion toward "no occlusion" by `occlusionTexture.strength`,
    /// so a strength of 0 lights the surface as if the map were absent.
    nonisolated static func weakenedOcclusionImage(_ image: CGImage, strength: Float) throws -> CGImage {
        try rewritingPixels(of: image) { pixels, pixelCount in
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                // glTF keeps occlusion in the red channel; the others follow it so the
                // result reads the same whichever channel is sampled.
                let occlusion = 1 + strength * (Float(pixels[offset]) / 255 - 1)
                let value = UInt8(clamping: Int((occlusion * 255).rounded()))
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
    }

    /// MToon's single-channel maps in one raw texture, each in the channel VRMC_materials_mtoon
    /// reads it from: the shading shift in red, the outline width in green and the UV animation
    /// mask in blue. Fewer CustomMaterial slots reach the shaders than MToon has textures, and
    /// these three leave each other's channels unread, so one slot carries them all. A single
    /// image, or one image shared by every map that is set, is used as it is. Nil when none is set.
    func mtoonMaskTexture(shadingShift: Int?, outlineWidth: Int?, uvAnimationMask: Int?) throws -> TextureResource? {
        let textureIndices = [shadingShift, outlineWidth, uvAnimationMask]
        let imageIndices = try textureIndices.map { try $0.map(gltf.imageIndex(ofTextureAt:)) }
        guard let textureIndex = textureIndices.compactMap({ $0 }).first else { return nil }
        guard Set(imageIndices.compactMap { $0 }).count > 1 else {
            return try texture(withTextureIndex: textureIndex, semantic: .raw)
        }
        if let cached = resources.mtoonMaskCache[imageIndices] { return cached }
        let packed = try Self.channelPackedImage(try imageIndices.map { try $0.map(image(withImageIndex:)) })
        let resource = try makeTextureResource(packed, semantic: .raw)
        resources.mtoonMaskCache[imageIndices] = resource
        return resource
    }

    /// An image whose channel `n` is channel `n` of `sources[n]`, each drawn at the size of the
    /// largest. A missing source leaves its channel white.
    nonisolated static func channelPackedImage(_ sources: [CGImage?]) throws -> CGImage {
        let width = sources.compactMap { $0?.width }.max() ?? 1
        let height = sources.compactMap { $0?.height }.max() ?? 1
        let bytesPerPixel = 4
        var packed = [UInt8](repeating: 255, count: width * height * bytesPerPixel)
        for (channel, source) in sources.enumerated() {
            guard let source else { continue }
            let pixels = try rgba8Pixels(of: source, width: width, height: height)
            for pixel in 0..<(width * height) {
                packed[pixel * bytesPerPixel + channel] = pixels[pixel * bytesPerPixel + channel]
            }
        }
        guard let provider = CGDataProvider(data: Data(packed) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * bytesPerPixel, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw VRMError._dataInconsistent("failed to create CGImage")
        }
        return image
    }

    /// `image` drawn into 8-bit RGBA at `width` x `height`.
    private nonisolated static func rgba8Pixels(of image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          // The maps are data, not color: alpha must not premultiply them.
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw VRMError._dataInconsistent("failed to create cgcontext")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private nonisolated static func rewritingPixels(of image: CGImage,
                                                    _ rewrite: (UnsafeMutablePointer<UInt8>, Int) -> Void) throws -> CGImage {
        try withRGBA8Pixels(of: image) { context, pixels, pixelCount in
            rewrite(pixels, pixelCount)
            return try context.makeImage() ??? .dataInconsistent("failed to create CGImage")
        }
    }

    /// Draws `image` into a freshly allocated 8-bit RGBA buffer and hands `body` that
    /// buffer, its pixel count and the context behind it, valid only for the call.
    private nonisolated static func withRGBA8Pixels<Result>(
        of image: CGImage,
        _ body: (CGContext, UnsafeMutablePointer<UInt8>, Int) throws -> Result
    ) throws -> Result {
        let bytesPerPixel = 4
        let pixelCount = image.width * image.height
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * bytesPerPixel)
        defer { pixels.deallocate() }

        guard let context = CGContext(
            data: UnsafeMutableRawPointer(pixels),
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerPixel * image.width,
            space: CGColorSpaceCreateDeviceRGB(),
            // The maps are data, not color: alpha must not premultiply them.
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw VRMError._dataInconsistent("failed to create cgcontext")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try body(context, pixels, pixelCount)
    }

    private func metallicRoughnessTextures(withTextureIndex index: Int) throws -> (metal: MaterialParameters.Texture, rough: MaterialParameters.Texture) {
        let imageIndex = try gltf.imageIndex(ofTextureAt: index)
        let split: (metal: TextureResource, rough: TextureResource)
        if let cache = resources.metallicRoughnessCache[imageIndex] {
            split = cache
        } else {
            // Split by the prepare pass off-actor, or now for an image it missed.
            let images = try prepared.metallicRoughnessImages[imageIndex]
                ?? metallicRoughnessImages(from: try image(withImageIndex: imageIndex))
            // Metallic / roughness are linear data; .color would apply an sRGB conversion.
            let textures = (try makeTextureResource(images.metal, semantic: .raw),
                            try makeTextureResource(images.rough, semantic: .raw))
            resources.metallicRoughnessCache[imageIndex] = textures
            split = textures
        }
        let sampler = try sampler(withTextureIndex: index)
        return (MaterialParameters.Texture(split.metal, sampler: sampler),
                MaterialParameters.Texture(split.rough, sampler: sampler))
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout UnlitMaterial) {
        let settings = GLTFAlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout PhysicallyBasedMaterial) {
        let settings = GLTFAlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

    /// The joints of the skin at `index`, parents first, as RealityKit poses them.
    func skeleton(withSkinIndex index: Int) throws -> MeshResource.Skeleton {
        if let cache = try loadCached(resources.skeletons, at: index, of: "skin") { return cache }
        let skin = try loadCached(resources.reader().skins, at: index, of: "skin")
        let nodes = gltf.nodes
        let joints = skin.joints.indices.map { joint in
            let nodeIndex = skin.joints[joint]
            return MeshResource.Skeleton.Joint(name: nodes[nodeIndex].name ?? "joint_\(nodeIndex)",
                                               parentIndex: skin.parents[joint],
                                               inverseBindPoseMatrix: skin.inverseBindMatrices[joint],
                                               restPoseTransform: nodes[nodeIndex].localTransform)
        }
        let skeleton = MeshResource.Skeleton(id: "skin_\(index)", joints: joints)
        resources.skeletons[index] = skeleton
        return skeleton
    }

    /// Binds the skinned models of a freshly cloned mesh to this scene's joints.
    private func registerSkinBindings(in meshRoot: Entity) throws {
        for modelEntity in meshRoot.modelEntitiesInHierarchy {
            guard let skinIndex = modelEntity.components[GLTFSkinIndexComponent.self]?.skinIndex else {
                continue
            }
            let skeleton = try skeleton(withSkinIndex: skinIndex)
            let jointEntities: [Entity]
            if let cached = jointEntitiesBySkin[skinIndex] {
                jointEntities = cached
            } else {
                // In the skeleton's order, parents first, which the pose follows.
                jointEntities = try loadCached(resources.reader().skins, at: skinIndex, of: "skin").joints.map {
                    try node(withNodeIndex: $0)
                }
                jointEntitiesBySkin[skinIndex] = jointEntities
            }
            root.registerSkinBinding(modelEntity: modelEntity,
                                     skeleton: skeleton,
                                     jointEntities: jointEntities)
        }
    }

    private func registerMaterialBindings(in meshRoot: Entity) {
        for modelEntity in meshRoot.modelEntitiesInHierarchy {
            guard let slots = modelEntity.components[GLTFMaterialSlotsComponent.self] else { continue }
            for (slot, materialIndex) in slots.materialIndices.enumerated() {
                guard let materialIndex else { continue }
                root.registerMaterialBinding(modelEntity: modelEntity,
                                             slot: slot,
                                             materialIndex: materialIndex,
                                             builder: self)
            }
        }
    }

    /// glTF's default material for a primitive that names none: lit, white, fully
    /// metallic and rough.
    static func defaultMaterial() -> Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white)
        material.metallic = .init(floatLiteral: 1.0)
        material.roughness = .init(floatLiteral: 1.0)
        return material
    }

}

#endif
