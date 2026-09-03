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
    var resolvedGeometryDecoder: GLTFGeometryDecoder?
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

    /// The merged meshes a first-person camera cuts, whose cut variant is generated
    /// after the load rather than during it.
    private(set) var firstPersonCatalogs: [GLTFMergedMeshCatalog] = []

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

    /// Generates the first-person variant of every cut mesh once the load has returned,
    /// off the actor, so the first camera switch finds it ready without the load paying
    /// for a mesh most sessions never draw. A switch landing first generates it on the spot.
    func prewarmFirstPersonMeshesInBackground() {
        let catalogs = firstPersonCatalogs
        guard !catalogs.isEmpty else { return }
        Task(priority: .utility) { @MainActor in
            for catalog in catalogs {
                do {
                    try await catalog.prewarmFirstPersonVariant()
                } catch {
                    GLTFResourceCache.gltfLogger.error("Failed to generate a first-person mesh: \(String(describing: error), privacy: .public)")
                }
            }
        }
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
        for (index, gltfMaterial) in (gltf.materials).enumerated() {
            let textures = sampledTextures(of: gltfMaterial)
            let selectedTexCoord = selectedTexCoord(withMaterialIndex: index)
            guard textures.allSatisfy({ $0.texCoord == selectedTexCoord }) else {
                throw VRMError._notSupported(
                    "this glTF requires KHR_texture_transform, and material \(index) samples UV sets other than \(selectedTexCoord), which this renderer cannot draw"
                )
            }
            let transforms = textures.map { $0.transform ?? GLTFUVTransform() }
            guard transforms.allSatisfy({ $0 == transforms.first }) else {
                throw VRMError._notSupported(
                    "this glTF requires KHR_texture_transform, and material \(index) gives its textures different transforms, which this renderer cannot draw"
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
            try applyInitialMorphWeights(of: gltfNode,
                                         meshIndex: meshIndex,
                                         targetCount: targetCount,
                                         to: modelEntities)
            root.registerMorphBindings(forNodeAt: index,
                                       modelEntities: modelEntities,
                                       targetCount: targetCount)
        }

        for child in gltfNode.children ?? [] {
            entity.addChild(try node(withNodeIndex: child))
        }
    }

    /// The number of morph targets the mesh at `index` renders with, one per weight in
    /// any array driving it. A primitive declaring no target of its own does not take part.
    func morphTargetCount(ofMeshAt index: Int) throws -> Int {
        if let cached = resources.morphTargetCounts[index] { return cached }
        var targetCount = 0
        for primitive in resolvedPrimitives(of: try gltf.load(\.meshes, at: index)) {
            let count = primitive.targets?.count ?? 0
            guard count > 0 else { continue }
            guard targetCount == 0 || targetCount == count else {
                throw VRMError._dataInconsistent(
                    "the primitives of mesh \(index) declare \(targetCount) and \(count) morph targets, but a mesh's primitives must all declare the same number"
                )
            }
            targetCount = count
        }
        resources.morphTargetCounts[index] = targetCount
        return targetCount
    }

    /// Applies the spec's starting morph state, `node.weights` falling back to
    /// `mesh.weights`. Both must be sized by the mesh's morph target count.
    private func applyInitialMorphWeights(of gltfNode: GLTF.Node,
                                          meshIndex: Int,
                                          targetCount: Int,
                                          to modelEntities: [ModelEntity]) throws {
        func validated(_ weights: [Float]?, _ source: @autoclosure () -> String) throws -> [Float]? {
            guard let weights else { return nil }
            guard weights.count == targetCount else {
                throw VRMError._dataInconsistent(
                    "\(source()) holds \(weights.count) weights but mesh \(meshIndex) has \(targetCount) morph targets"
                )
            }
            return weights
        }
        let meshWeights = try validated(gltf.load(\.meshes, at: meshIndex).weights, "mesh \(meshIndex)")
        let nodeWeights = try validated(gltfNode.weights, "a node rendering mesh \(meshIndex)")

        guard let weights = nodeWeights ?? meshWeights, weights.contains(where: { $0 != 0 }) else { return }
        for modelEntity in modelEntities where modelEntity.components.has(BlendShapeWeightsComponent.self) {
            modelEntity.applyMorphWeights(weights)
        }
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
        let headJoints = try headJoints(ofNodeAt: nodeIndex, meshIndex: index, skinIndex: skinIndex)
        // Built once per template and cloned per node: the clones share the `MeshResource`
        // and carry their own pose and weights.
        let meshEntity = try meshTemplate(withMeshIndex: index,
                                          skinIndex: skinIndex,
                                          headJoints: headJoints).clone(recursive: true)
        try registerSkinBindings(in: meshEntity)
        registerMaterialBindings(in: meshEntity)
        sceneMeshes[index, default: []].append(.init(nodeIndex: nodeIndex, entity: meshEntity))
        return meshEntity
    }

    /// The clone source for one mesh as one node draws it, which never joins a scene.
    private func meshTemplate(withMeshIndex index: Int,
                              skinIndex: Int?,
                              headJoints: Set<UInt32>) throws -> Entity {
        let key = GLTFResourceCache.MeshTemplateKey(meshIndex: index,
                                                    skinIndex: skinIndex,
                                                    cutsHead: !headJoints.isEmpty)
        if let cache = resources.meshTemplates[key] { return cache }
        let template = try makeMeshEntity(withMeshIndex: index, skinIndex: skinIndex, headJoints: headJoints)
        resources.meshTemplates[key] = template
        return template
    }

    private func makeMeshEntity(withMeshIndex index: Int,
                                skinIndex: Int?,
                                headJoints: Set<UInt32>) throws -> Entity {
        let gltfMesh = try gltf.load(\.meshes, at: index)
        let meshEntity = Entity()
        meshEntity.name = gltfMesh.name ?? "mesh_\(index)"

        var primitives: [MergedPrimitive] = []
        for (primitiveIndex, primitive) in resolvedPrimitives(of: gltfMesh).enumerated() {
            if let merged = try mergedPrimitive(primitive,
                                                at: primitiveIndex,
                                                ofMeshAt: index,
                                                skinIndex: skinIndex,
                                                headJoints: headJoints) {
                primitives.append(merged)
            }
        }
        guard !primitives.isEmpty else { return meshEntity }

        // A skinned mesh's primitives all bind the one skin the node names, so the
        // merged parts share its skeleton.
        let skeleton = primitives.contains(where: \.isSkinned)
            ? try skinIndex.map { try skin(withSkinIndex: $0).skeleton }
            : nil

        // Each distinct pass of the mesh's materials becomes one sibling model entity
        // bundling every primitive whose material draws it, in first-appearance order.
        var passNames: [String] = []
        var passSlots: [String: [(primitive: MergedPrimitive, pass: GLTFShadedMaterial.Pass)]] = [:]
        for primitive in primitives {
            for pass in primitive.shaded.additionalPasses {
                if passSlots[pass.name] == nil { passNames.append(pass.name) }
                passSlots[pass.name, default: []].append((primitive, pass))
            }
        }
        for name in passNames {
            guard let slots = passSlots[name] else { continue }
            let passEntity = try makeMergedModelEntity(
                name: "\(meshEntity.name)_\(name)",
                modelID: "mesh_\(index)_\(name)",
                primitives: slots.map(\.primitive),
                materials: slots.map(\.pass.material),
                initiallyVisibleSlots: slots.map(\.pass.isInitiallyEnabled),
                skeleton: skeleton,
                skinIndex: skinIndex)
            passEntity.components.set(GLTFMaterialPassComponent(name: name))
            grantBoundsBudget(to: passEntity, passes: slots.map(\.pass))
            // The passes go on before the main model entity, keeping their draw order.
            meshEntity.addChild(passEntity)
        }

        meshEntity.addChild(try makeMergedModelEntity(
            name: "\(meshEntity.name)_model",
            modelID: "mesh_\(index)",
            primitives: primitives,
            materials: primitives.map(\.shaded.material),
            initiallyVisibleSlots: primitives.map { _ in true },
            skeleton: skeleton,
            skinIndex: skinIndex))
        return meshEntity
    }

    /// The primitives a mesh is built from, as the profile reads them off the document.
    func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] {
        resources.profile.resolvedPrimitives(of: mesh)
    }

    /// The joints of `skinIndex` whose triangles a first-person camera drops from the mesh
    /// the node at `nodeIndex` draws. Empty for a plain glTF.
    func headJoints(ofNodeAt nodeIndex: Int, meshIndex: Int, skinIndex: Int?) throws -> Set<UInt32> {
        resources.profile.headJoints(ofNodeAt: nodeIndex,
                                     meshIndex: meshIndex,
                                     skinIndex: skinIndex,
                                     hierarchy: try resources.nodeHierarchy())
    }

    /// One primitive of a mesh, decoded and shaded, ready to merge into the mesh's
    /// model entities as one part each.
    private struct MergedPrimitive {
        let materialIndex: Int?
        let shaded: GLTFShadedMaterial
        /// The part's `materialIndex` is set to its slot by the entity taking it.
        let part: MeshResource.Part
        /// What a first-person camera draws of the part.
        let firstPersonMask: FirstPersonPrimitiveMask
        let hasBlendShapes: Bool
        let isSkinned: Bool
    }

    private func mergedPrimitive(_ primitive: GLTF.Mesh.Primitive,
                                 at primitiveIndex: Int,
                                 ofMeshAt meshIndex: Int,
                                 skinIndex: Int?,
                                 headJoints: Set<UInt32>) throws -> MergedPrimitive? {
        let key = PrimitiveGeometryKey(meshIndex: meshIndex, primitiveIndex: primitiveIndex, skinIndex: skinIndex)
        guard let prepared = try preparedPrimitive(forKey: key, primitive: primitive, headJoints: headJoints) else {
            resources.logOnce("primitiveMode-\(primitive.mode)", """
                A \(primitive.mode) primitive was skipped; RealityKit meshes render triangles only.
                """)
            return nil
        }
        let geometry = prepared.geometry
        for warning in geometry.warnings {
            resources.logOnce(warning.key, warning.message)
        }

        let shaded = try primitive.material.map { try shadedMaterial(withMaterialIndex: $0) }
            ?? GLTFShadedMaterial(material: Self.defaultMaterial())

        var jointInfluences: MeshResource.JointInfluences?
        var skeletonID: String?
        if let skinIndex, let influences = prepared.jointInfluences {
            jointInfluences = MeshResource.JointInfluences(influences: MeshBuffer(influences), influencesPerVertex: 4)
            skeletonID = try skin(withSkinIndex: skinIndex).skeleton.id
        }
        return MergedPrimitive(materialIndex: primitive.material,
                               shaded: shaded,
                               part: makePart(id: "primitive_\(primitiveIndex)",
                                              geometry: geometry,
                                              skeletonID: skeletonID,
                                              jointInfluences: jointInfluences),
                               firstPersonMask: prepared.firstPersonMask,
                               hasBlendShapes: !geometry.blendShapeOffsets.isEmpty,
                               isSkinned: geometry.isSkinned)
    }

    /// One model entity drawing `primitives` as the parts of one mesh, each
    /// addressing its material by slot.
    private func makeMergedModelEntity(name: String,
                                       modelID: String,
                                       primitives: [MergedPrimitive],
                                       materials: [Material],
                                       initiallyVisibleSlots: [Bool],
                                       skeleton: MeshResource.Skeleton?,
                                       skinIndex: Int?) throws -> ModelEntity {
        var parts: [MeshResource.Part] = []
        parts.reserveCapacity(primitives.count)
        for (slot, primitive) in primitives.enumerated() {
            var part = primitive.part
            part.materialIndex = slot
            parts.append(part)
        }
        let mesh = try meshResource(modelID: modelID, parts: parts, skeleton: skeleton)

        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.name = name
        entity.components.set(GLTFMaterialSlotsComponent(materialIndices: primitives.map(\.materialIndex)))
        if primitives.contains(where: \.hasBlendShapes) {
            entity.components.set(BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: mesh)))
        }
        if let skinIndex, skeleton != nil {
            // The binding is registered per clone, once its joints exist.
            entity.components.set(GLTFSkinIndexComponent(skinIndex: skinIndex))
        }

        let catalog = GLTFMergedMeshCatalog(
            fullMesh: mesh,
            slots: zip(primitives, initiallyVisibleSlots).map { primitive, isVisible in
                .init(partID: primitive.part.id,
                      firstPersonMask: primitive.firstPersonMask,
                      isInitiallyVisible: isVisible)
            })
        entity.components.set(GLTFMergedMeshComponent(catalog: catalog,
                                                      visibleSlots: initiallyVisibleSlots))
        if initiallyVisibleSlots.contains(false) {
            entity.applyMergedMesh()
        }
        if catalog.hasFirstPersonCut {
            firstPersonCatalogs.append(catalog)
        }
        return entity
    }

    /// Widens the bounding box RealityKit culls `passEntity` by, so a geometry modifier
    /// pushing vertices outward is not culled while on screen, and tells each slot's
    /// modifier how much room it got.
    private func grantBoundsBudget(to passEntity: ModelEntity,
                                   passes: [GLTFShadedMaterial.Pass]) {
        guard passes.contains(where: { $0.applyBoundsBudget != nil }),
              var component = passEntity.components[ModelComponent.self] else { return }
        // The budget covers the whole merged mesh, hidden slots included, so a slot
        // shown later still fits it.
        let budget = (passEntity.mergedMesh?.catalog.fullMesh ?? component.mesh).bounds.boundingRadius
        component.boundsMargin = budget
        for (slot, pass) in passes.enumerated() {
            guard let applyBudget = pass.applyBoundsBudget,
                  component.materials.indices.contains(slot) else { continue }
            component.materials[slot] = applyBudget(component.materials[slot], budget)
        }
        passEntity.components.set(component)
    }

    /// The UV set the meshes rendering `index` carry, and whether the material's textures
    /// disagree about it. Custom meshes carry a single UV channel, so the core material's
    /// first UV-accessed texture decides it.
    func resolvedTexCoord(withMaterialIndex index: Int) -> (selected: Int, isMixed: Bool) {
        if let cached = resources.materialTexCoordCache[index] { return cached }
        guard let gltfMaterial = try? gltf.load(\.materials, at: index) else { return (0, false) }
        let textures = sampledTextures(of: gltfMaterial)
        let resolved = (selected: textures.first?.texCoord ?? 0,
                        isMixed: textures.contains { $0.texCoord != textures.first?.texCoord })
        resources.materialTexCoordCache[index] = resolved
        return resolved
    }

    /// A shader sampling any other set renders through this one.
    func selectedTexCoord(withMaterialIndex index: Int) -> Int {
        resolvedTexCoord(withMaterialIndex: index).selected
    }

    /// Whether the material samples a normal map, which decides whether a primitive without
    /// `TANGENT` needs a tangent basis generating. The MToon descriptor is asked first
    /// because VRM 0.x carries its normal map in Unity's `_BumpMap`.
    func materialSamplesNormalTexture(withMaterialIndex index: Int) -> Bool {
        if let descriptor = try? mtoonDescriptor(withMaterialIndex: index), descriptor.normalTexture != nil {
            return true
        }
        guard let (gltfMaterial, _) = try? materialSource(withMaterialIndex: index) else { return false }
        return gltfMaterial.normalTexture != nil
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
            guard let fallback = resources.profile.shadedMaterialFallback(for: context, error: error) else { throw error }
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
        return GLTFShadedMaterial(material: try standardMaterial(for: context))
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
        let resolvedAlphaMode = GLTF.Material.AlphaMode(vrm0: materialProperty,
                                                        fallback: gltfMaterial.alphaMode)
        let tint = gltfMaterial.pbrMetallicRoughness
            .map { VRMColor(simd: $0.baseColorFactor) } ?? .white

        if useUnlit {
            // RealityKit's tone mapping visibly darkens flat art, so opt out of it.
            var material = UnlitMaterial(applyPostProcessToneMap: false)
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
        let emissiveTint = VRMColor(red: CGFloat(emissiveFactor.x),
                                   green: CGFloat(emissiveFactor.y),
                                   blue: CGFloat(emissiveFactor.z),
                                   alpha: 1)
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

    /// The textures a standard (non-MToon) material samples through mesh UVs, in the
    /// order the glTF material declares them.
    private func sampledTextures(of gltfMaterial: GLTF.Material) -> [GLTFSampledTexture] {
        var textures: [GLTFSampledTexture] = []
        if let pbr = gltfMaterial.pbrMetallicRoughness {
            if let info = pbr.baseColorTexture { textures.append(GLTFSampledTexture(info)) }
            if let info = pbr.metallicRoughnessTexture { textures.append(GLTFSampledTexture(info)) }
        }
        if let info = gltfMaterial.normalTexture { textures.append(GLTFSampledTexture(info)) }
        if let info = gltfMaterial.occlusionTexture { textures.append(GLTFSampledTexture(info)) }
        if let info = gltfMaterial.emissiveTexture { textures.append(GLTFSampledTexture(info)) }
        return textures
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
                                            textures: sampledTextures(of: gltfMaterial))
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

    /// The materials this builder's scene draws with.
    private func drawnMaterialIndices() throws -> Set<Int> {
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
            uploads.append(TextureUpload(key: key, image: try image(withImageIndex: key.imageIndex)))
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
        return try TextureResource(image: image, options: .init(semantic: semantic))
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
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: image.bitmapInfo.rawValue),
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

    /// The skin at `index` resolved for RealityKit. Its skeleton and joint remap come
    /// out of the same ordering pass, so they are cached together.
    func skin(withSkinIndex index: Int) throws -> GLTFResourceCache.Skin {
        if let cache = try loadCached(resources.skins, at: index, of: "skin") { return cache }
        let skin = try gltf.load(\.skins, at: index)
        let nodes = gltf.nodes
        let (parentIndices, order, remap) = try computeSkinJointOrdering(skin: skin)

        // glTF defines an absent inverseBindMatrices as identity per joint, but a present
        // one has to cover every joint.
        let inverseBindMatrices: [simd_float4x4]
        if let accessorIndex = skin.inverseBindMatrices {
            inverseBindMatrices = try accessors.accessor(at: accessorIndex).float4x4Elements()
            guard inverseBindMatrices.count >= skin.joints.count else {
                throw VRMError._dataInconsistent(
                    "inverseBindMatrices has \(inverseBindMatrices.count) elements for \(skin.joints.count) skin joints"
                )
            }
        } else {
            inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: skin.joints.count)
        }

        var joints: [MeshResource.Skeleton.Joint] = []
        joints.reserveCapacity(order.count)
        for newIndex in 0..<order.count {
            let oldIndex = order[newIndex]
            let nodeIndex = skin.joints[oldIndex]
            let node = nodes[nodeIndex]
            let name = node.name ?? "joint_\(nodeIndex)"
            let parentOld = parentIndices[oldIndex]
            let parentNew = parentOld.map { remap[$0] }

            let restTransform = node.localTransform
            let ibm = inverseBindMatrices[oldIndex]
            joints.append(.init(name: name,
                                parentIndex: parentNew,
                                inverseBindPoseMatrix: ibm,
                                restPoseTransform: restTransform))
        }

        let resolved = GLTFResourceCache.Skin(skeleton: MeshResource.Skeleton(id: "skin_\(index)", joints: joints),
                                              jointIndexRemap: remap)
        resources.skins[index] = resolved
        return resolved
    }

    private func computeSkinJointOrdering(skin: GLTF.Skin) throws -> (parentIndices: [Int?], order: [Int], remap: [Int]) {
        let jointNodeIndices = skin.joints
        let jointIndexMap = Dictionary(uniqueKeysWithValues: jointNodeIndices.enumerated().map { ($0.element, $0.offset) })
        var parentIndices: [Int?] = Array(repeating: nil, count: jointNodeIndices.count)
        let hierarchy = try resources.nodeHierarchy()
        for (i, nodeIndex) in jointNodeIndices.enumerated() {
            // The validated hierarchy is a forest, so walking up terminates.
            var current = nodeIndex
            while let parent = hierarchy.parent(at: current) {
                if let jointIndex = jointIndexMap[parent] {
                    parentIndices[i] = jointIndex
                    break
                }
                current = parent
            }
        }

        var children: [[Int]] = Array(repeating: [], count: jointNodeIndices.count)
        for (i, parent) in parentIndices.enumerated() {
            if let parent = parent {
                children[parent].append(i)
            }
        }

        var order: [Int] = []
        order.reserveCapacity(jointNodeIndices.count)
        func visit(_ index: Int) {
            order.append(index)
            for child in children[index] {
                visit(child)
            }
        }

        // The validated hierarchy is a forest, so visiting every root reaches every joint.
        let roots = parentIndices.enumerated().compactMap { $0.element == nil ? $0.offset : nil }
        for root in roots {
            visit(root)
        }

        var remap: [Int] = Array(repeating: 0, count: jointNodeIndices.count)
        for (newIndex, oldIndex) in order.enumerated() {
            remap[oldIndex] = newIndex
        }

        return (parentIndices, order, remap)
    }

    private func makePart(id: String,
                          geometry: GLTFPrimitiveGeometry,
                          skeletonID: String?,
                          jointInfluences: MeshResource.JointInfluences?) -> MeshResource.Part {
        var part = MeshResource.Part(id: id, materialIndex: 0)
        part.positions = MeshBuffer(geometry.positions)
        if !geometry.normals.isEmpty {
            part.normals = MeshBuffer(geometry.normals)
        }
        if !geometry.tangents.isEmpty {
            part.tangents = MeshBuffer(geometry.tangents)
            part.bitangents = MeshBuffer(geometry.bitangents)
        }
        if !geometry.texcoords.isEmpty {
            part.textureCoordinates = MeshBuffer(geometry.texcoords)
        }
        part.triangleIndices = MeshBuffer(geometry.indices)
        if !geometry.blendShapeOffsets.isEmpty {
            for (targetIndex, offsets) in geometry.blendShapeOffsets.enumerated() {
                let name = "blendShape_\(targetIndex)"
                part.setBlendShapeOffsets(named: name, buffer: MeshBuffer(offsets))
            }
            _ = part.blendShapeNames
        }
        if let skeletonID, let jointInfluences {
            part.skeletonID = skeletonID
            part.jointInfluences = jointInfluences
        }
        return part
    }

    private func meshResource(modelID: String,
                              parts: [MeshResource.Part],
                              skeleton: MeshResource.Skeleton?) throws -> MeshResource {
        var models = MeshModelCollection()
        _ = models.insert(MeshResource.Model(id: modelID, parts: parts))

        var instances = MeshInstanceCollection()
        _ = instances.insert(MeshResource.Instance(id: modelID, model: modelID))

        var contents = MeshResource.Contents()
        contents.models = models
        contents.instances = instances
        if let skeleton {
            var skeletons = MeshSkeletonCollection()
            _ = skeletons.insert(skeleton)
            contents.skeletons = skeletons
        }

        let started = ContinuousClock.now
        defer {
            timings.meshResources += ContinuousClock.now - started
            timings.meshResourceCount += 1
        }
        return try MeshResource.generate(from: contents)
    }

    /// Binds the skinned models of a freshly cloned mesh to this scene's joints.
    private func registerSkinBindings(in meshRoot: Entity) throws {
        for modelEntity in meshRoot.modelEntitiesInHierarchy {
            guard let skinIndex = modelEntity.components[GLTFSkinIndexComponent.self]?.skinIndex else {
                continue
            }
            let skin = try skin(withSkinIndex: skinIndex)
            let jointEntities: [Entity]
            if let cached = jointEntitiesBySkin[skinIndex] {
                jointEntities = cached
            } else {
                let jointNodes = try gltf.load(\.skins, at: skinIndex).joints
                let jointsInSkinOrder = try jointNodes.map { try node(withNodeIndex: $0) }
                // The skeleton reorders the joints parents-first, and the pose follows it.
                var reordered = jointsInSkinOrder
                for (oldIndex, newIndex) in skin.jointIndexRemap.enumerated() {
                    reordered[newIndex] = jointsInSkinOrder[oldIndex]
                }
                jointEntitiesBySkin[skinIndex] = reordered
                jointEntities = reordered
            }
            root.registerSkinBinding(modelEntity: modelEntity,
                                     skeleton: skin.skeleton,
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
