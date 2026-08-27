#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import Metal
import OSLog
import VRMKit
import VRMKitRuntime

/// Loads a plain glTF / GLB document into a RealityKit entity graph.
///
/// ``VRMEntityLoader`` subclasses it to add the VRM-specific runtime on top.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public class GLTFEntityLoader {
    public let document: GLTFDocument
    var gltf: GLTF { document.gltf }
    let entityData: EntityData
    /// Accessors expanded for this loader's meshes and skins, shared by the
    /// primitives that reference the same one.
    let accessors: PackedAccessorCache

    /// Name given to the loaded root entity. Subclasses set it from model metadata.
    var entityName: String?
    weak var currentEntity: GLTFEntity?
    static let gltfLogger = Logger(subsystem: "dev.tattn.VRMKit", category: "glTF")

    /// Node parents, built and validated once by ``validateStructure()``.
    private(set) var nodeHierarchy: GLTFNodeHierarchy?
    private var loggedLimitations: Set<String> = []
    private var materialTexCoordCache: [Int: (selected: Int, isMixed: Bool)] = [:]
    private var morphTargetCounts: [Int: Int] = [:]

    func logOnce(_ key: String, _ message: @autoclosure () -> String) {
        guard loggedLimitations.insert(key).inserted else { return }
        let text = message()
        Self.gltfLogger.warning("\(text, privacy: .public)")
    }

    /// One glTF image decoded for one semantic: RealityKit bakes the semantic
    /// into the resource, so an image read as color and as a normal map is two.
    /// Keying on the image, not the texture, shares the decode between textures
    /// that differ only in their sampler.
    private struct ImageTextureKey: Hashable {
        let imageIndex: Int
        let semantic: TextureResource.Semantic
    }

    private var textureCache: [ImageTextureKey: TextureResource] = [:]
    /// Metal and roughness split out of one image's channels.
    private var metallicRoughnessCache: [Int: (metal: TextureResource, rough: TextureResource)] = [:]
    /// One glTF image read through a scalar factor baked into its pixels.
    private struct BakedTextureKey: Hashable {
        let imageIndex: Int
        let factor: Float
        let semantic: TextureResource.Semantic
    }

    private var bakedTextureCache: [BakedTextureKey: TextureResource] = [:]
    /// Keyed by glTF sampler index; nil is the texture that names no sampler.
    private var samplerCache: [Int?: MaterialParameters.Texture.Sampler] = [:]
    private var mtoonResolutionCache: [Int: MToonMaterialDescriptor.Resolution] = [:]

    /// The material shaders this loader consults, in order. Materials no shader
    /// claims render through the built-in Unlit / PBR path, so pass `[]` to
    /// render everything that way.
    public let shaders: [any GLTFMaterialShader]

    /// The default shader chain: MToon for materials that carry MToon data.
    /// Computed so every loader gets its own shader instances.
    public static var defaultShaders: [any GLTFMaterialShader] { [MToonShader()] }

    public init(document: GLTFDocument,
                shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) {
        self.document = document
        self.entityData = EntityData(gltf: document.gltf)
        self.accessors = PackedAccessorCache(document: document)
        self.shaders = shaders
    }

    /// Loads a `.glb` / `.gltf` file. External resources resolve relative to
    /// the file's directory.
    public convenience init(withURL url: URL,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(document: try GLTFDocument(withURL: url), shaders: shaders)
    }

    /// Loads a bundled glTF resource.
    public convenience init(named: String,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(document: try GLTFDocument(named: named), shaders: shaders)
    }

    /// Loads in-memory glTF data. `rootDirectory` is the base directory for
    /// external resources.
    public convenience init(withData data: Data,
                            rootDirectory: URL? = nil,
                            shaders: [any GLTFMaterialShader] = GLTFEntityLoader.defaultShaders) throws {
        self.init(document: try GLTFDocument(data: data, rootDirectory: rootDirectory),
                  shaders: shaders)
    }

    /// Loads the document's default scene, decoding its primitives concurrently
    /// off the actor the entity graph is built on.
    ///
    /// - Throws: when the glTF holds several scenes and names no default one.
    ///   Pick one with ``loadEntity(withSceneIndex:)``.
    public func loadEntity() async throws -> GLTFEntity {
        try await loadEntity(withSceneIndex: gltf.defaultSceneIndex())
    }

    /// Loads one scene of the glTF as its own entity graph. The document is
    /// validated before any vertex data is read, and every call builds a new
    /// graph, even for the same scene, while resources are reused.
    public func loadEntity(withSceneIndex index: Int) async throws -> GLTFEntity {
        try validateDocument()
        try await prepareGeometry(forSceneIndex: index)
        try Task.checkCancellation()
        return try buildScene(withSceneIndex: index)
    }

    /// Checks the required extensions, node graph and skins before any vertex is read.
    private func validateDocument() throws {
        try validateRequiredExtensions()
        try validateStructure()
    }

    /// Builds the entity graph of one scene from an already validated document.
    private func buildScene(withSceneIndex index: Int) throws -> GLTFEntity {
        let gltfScene = try gltf.load(\.scenes, at: index)
        entityData.beginScene()
        // Vertex data lives on in the mesh resources the build makes of it, so
        // holding the intermediates past it is a second copy of the model.
        defer {
            entityData.primitiveGeometries.removeAll()
            accessors.removeAll()
        }

        let entity = makeRootEntity(sceneIndex: index)
        if let entityName {
            entity.name = entityName
        }
        currentEntity = entity
        defer { currentEntity = nil }
        try nodeHierarchy?.validateSceneRoots(gltfScene.nodes ?? [], sceneIndex: index)
        for node in gltfScene.nodes ?? [] {
            entity.addChild(try self.node(withNodeIndex: node))
        }
        entity.setNodeEntities(entityData.nodes)
        try didBuildScene(entity)
        // Skin bindings are registered mid-build, so the rest pose is only
        // solvable once the graph is complete.
        entity.updateSkinning()

        return entity
    }

    /// The root entity a scene load fills in.
    func makeRootEntity(sceneIndex: Int) -> GLTFEntity {
        GLTFEntity(document: document, sceneIndex: sceneIndex)
    }

    /// Called once per scene, after its node hierarchy and bindings are built.
    func didBuildScene(_ entity: GLTFEntity) throws {}

    /// glTF extensions this renderer implements, to satisfy `extensionsRequired`:
    /// the built-in ones plus whatever the shader chain claims.
    public var supportedRequiredExtensions: Set<String> {
        var extensions: Set<String> = [GLTFExtension.materialsUnlit.rawValue,
                                       GLTFExtension.textureTransform.rawValue]
        for shader in shaders {
            extensions.formUnion(shader.supportedRequiredExtensions)
        }
        return extensions
    }

    /// Fails the load when the file requires an extension this renderer does not
    /// implement, or leans on one past what is implemented of it.
    func validateRequiredExtensions() throws {
        if let unsupported = unsupportedRequiredExtensions().first {
            throw VRMError._notSupported("this glTF requires the \(unsupported) extension")
        }
        if enforcesRequiredExtension(GLTFExtension.textureTransform.rawValue) {
            try validateTextureTransformsAreRenderable()
        }
    }

    /// RealityKit gives a material one UV transform and its mesh one UV set, so
    /// `KHR_texture_transform` is only fully implemented while a material's
    /// textures agree on both. An asset that merely uses the extension renders
    /// through the first UV-accessed texture's set and transform and logs the
    /// approximation; one that requires it is rejected instead.
    private func validateTextureTransformsAreRenderable() throws {
        for (index, gltfMaterial) in (gltf.materials ?? []).enumerated() {
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

    /// Whether the document declares itself undrawable without `name` and this
    /// load honors that, which tells a shader to fail a material rather than
    /// approximate it. ``VRMEntityLoader`` renders whatever it can build, so it
    /// answers false even for a listed extension.
    func enforcesRequiredExtension(_ name: String) -> Bool {
        gltf.extensionsRequired?.contains(name) == true
    }

    /// `extensionsRequired` entries outside ``supportedRequiredExtensions``.
    func unsupportedRequiredExtensions() -> [String] {
        let supported = supportedRequiredExtensions
        return (gltf.extensionsRequired ?? []).filter { !supported.contains($0) }
    }

    /// Validates the node graph and skins, once per document.
    private func validateStructure() throws {
        guard nodeHierarchy == nil else { return }
        nodeHierarchy = try GLTFNodeHierarchy.validatingStructure(of: gltf)
    }

    func node(withNodeIndex index: Int) throws -> Entity {
        if let cache = try entityData.load(\.nodes, index: index) { return cache }

        let entity = Entity()
        // A skinned mesh may sit below one of its own joints, so publishing the
        // entity before its subtree exists ends that recursion.
        entityData.nodes[index] = entity
        do {
            try build(entity, forNodeAt: index)
        } catch {
            entityData.nodes[index] = nil
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
            currentEntity?.registerMorphBindings(forNodeAt: index,
                                                 modelEntities: modelEntities,
                                                 targetCount: targetCount)
        }

        for child in gltfNode.children ?? [] {
            entity.addChild(try node(withNodeIndex: child))
        }
    }

    /// The number of morph targets the mesh at `index` renders with, which every
    /// weights array driving it holds one weight for. A primitive declaring no
    /// target of its own does not take part.
    func morphTargetCount(ofMeshAt index: Int) throws -> Int {
        if let cached = morphTargetCounts[index] { return cached }
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
        morphTargetCounts[index] = targetCount
        return targetCount
    }

    /// Applies the spec's starting morph state, `node.weights` falling back to
    /// `mesh.weights`. Both have to be sized by the mesh's morph target count.
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
        let headJoints = firstPersonHeadJoints(ofNodeAt: nodeIndex, meshIndex: index, skinIndex: skinIndex)
        // Built once per template and cloned per node: the clones share the
        // `MeshResource` and carry their own pose and weights.
        let meshEntity = try meshTemplate(withMeshIndex: index,
                                          skinIndex: skinIndex,
                                          headJoints: headJoints).clone(recursive: true)
        try registerSkinBindings(in: meshEntity)
        registerMaterialBindings(in: meshEntity)
        entityData.sceneMeshes[index, default: []].append(.init(nodeIndex: nodeIndex, entity: meshEntity))
        return meshEntity
    }

    /// The clone source for one mesh as one node draws it, which never joins a
    /// scene itself.
    private func meshTemplate(withMeshIndex index: Int,
                              skinIndex: Int?,
                              headJoints: Set<UInt32>) throws -> Entity {
        let key = EntityData.MeshTemplateKey(meshIndex: index,
                                             skinIndex: skinIndex,
                                             cutsHead: !headJoints.isEmpty)
        if let cache = entityData.meshTemplates[key] { return cache }
        let template = try makeMeshEntity(withMeshIndex: index, skinIndex: skinIndex, headJoints: headJoints)
        entityData.meshTemplates[key] = template
        return template
    }

    private func makeMeshEntity(withMeshIndex index: Int,
                                skinIndex: Int?,
                                headJoints: Set<UInt32>) throws -> Entity {
        let gltfMesh = try gltf.load(\.meshes, at: index)
        let meshEntity = Entity()
        meshEntity.name = gltfMesh.name ?? "mesh_\(index)"

        for (primitiveIndex, primitive) in resolvedPrimitives(of: gltfMesh).enumerated() {
            if let primitiveEntity = try modelEntity(withPrimitive: primitive,
                                                     at: primitiveIndex,
                                                     ofMeshAt: index,
                                                     skinIndex: skinIndex,
                                                     headJoints: headJoints,
                                                     meshName: meshEntity.name) {
                meshEntity.addChild(primitiveEntity)
            }
        }
        return meshEntity
    }

    /// The primitives a mesh is built from, as the document declares them.
    /// ``VRMEntityLoader`` overrides it to reproduce VRM's morph target sharing.
    func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] {
        mesh.primitives
    }

    /// The joints of `skinIndex` whose triangles a first-person camera drops
    /// from the mesh the node at `nodeIndex` draws. Empty for a plain glTF,
    /// which has no such camera; ``VRMEntityLoader`` overrides it.
    func firstPersonHeadJoints(ofNodeAt nodeIndex: Int, meshIndex: Int, skinIndex: Int?) -> Set<UInt32> { [] }

    private func modelEntity(withPrimitive primitive: GLTF.Mesh.Primitive,
                             at primitiveIndex: Int,
                             ofMeshAt meshIndex: Int,
                             skinIndex: Int?,
                             headJoints: Set<UInt32>,
                             meshName: String) throws -> Entity? {
        let key = PrimitiveGeometryKey(meshIndex: meshIndex, primitiveIndex: primitiveIndex, skinIndex: skinIndex)
        guard let geometry = try decodedGeometry(forKey: key, primitive: primitive) else {
            logOnce("primitiveMode-\(primitive.mode)", """
                A \(primitive.mode) primitive was skipped; RealityKit meshes render triangles only.
                """)
            return nil
        }
        for warning in geometry.warnings {
            logOnce(warning.key, warning.message)
        }

        let shaded = try primitive.material.map { try shadedMaterial(withMaterialIndex: $0) }
            ?? GLTFShadedMaterial(material: defaultMaterial())

        // A skinned primitive binds its vertex influences to the skin's skeleton;
        // an unskinned one has neither.
        var skinSkeleton: MeshResource.Skeleton?
        var jointInfluences: MeshResource.JointInfluences?
        if let skinIndex, geometry.isSkinned {
            jointInfluences = try makeJointInfluences(joints: geometry.joints,
                                                      weights: geometry.weights,
                                                      vertexCount: geometry.positions.count,
                                                      jointIndexRemap: geometry.jointIndexRemap)
            skinSkeleton = try skin(withSkinIndex: skinIndex).skeleton
        }
        let mesh = try meshResource(geometry: geometry,
                                    skeleton: skinSkeleton,
                                    jointInfluences: jointInfluences)

        let blendShapeMapping = geometry.blendShapeOffsets.isEmpty
            ? nil
            : BlendShapeWeightsMapping(meshResource: mesh)

        let firstPerson = try firstPersonMesh(of: geometry,
                                             drawnAs: mesh,
                                             headJoints: headJoints,
                                             skeleton: skinSkeleton,
                                             jointInfluences: jointInfluences)

        func makeEntity(materials: [Material]) -> ModelEntity {
            let entity = ModelEntity(mesh: mesh, materials: materials)
            if let materialIndex = primitive.material {
                entity.components.set(GLTFMaterialIndexComponent(materialIndex: materialIndex))
            }
            if let blendShapeMapping {
                entity.components.set(BlendShapeWeightsComponent(weightsMapping: blendShapeMapping))
            }
            if let skinIndex, skinSkeleton != nil {
                // The binding itself is registered per clone, once the entity is
                // part of a scene and its joints exist.
                entity.components.set(GLTFSkinIndexComponent(skinIndex: skinIndex))
            }
            return entity
        }

        let modelEntity = makeEntity(materials: [shaded.material])
        if !shaded.additionalPasses.isEmpty {
            let container = Entity()
            container.name = "\(meshName)_container"
            for pass in shaded.additionalPasses {
                let passEntity = makeEntity(materials: [pass.material])
                passEntity.name = "\(meshName)_\(pass.name)"
                passEntity.components.set(GLTFMaterialPassComponent(name: pass.name,
                                                                   isInitiallyEnabled: pass.isInitiallyEnabled))
                passEntity.isEnabled = pass.isInitiallyEnabled
                if let applyBoundsBudget = pass.applyBoundsBudget {
                    grantBoundsBudget(to: passEntity, mesh: mesh, applying: applyBoundsBudget)
                }
                container.addChild(passEntity)
            }
            container.addChild(modelEntity)
            // The passes of one primitive are cut together, so it goes on what holds them.
            if let firstPerson { container.components.set(firstPerson) }
            return container
        }
        if let firstPerson { modelEntity.components.set(firstPerson) }
        return modelEntity
    }

    /// The same primitive with the head's triangles taken out, which is what a
    /// first-person camera draws of an `auto` mesh. Nil for one it does not cut.
    private func firstPersonMesh(of geometry: GLTFPrimitiveGeometry,
                                 drawnAs mesh: MeshResource,
                                 headJoints: Set<UInt32>,
                                 skeleton: MeshResource.Skeleton?,
                                 jointInfluences: MeshResource.JointInfluences?) throws -> FirstPersonMeshComponent? {
        switch FirstPersonAutoMask.mask(indices: geometry.indices,
                                        joints: geometry.joints,
                                        weights: geometry.weights,
                                        headJoints: headJoints) {
        case .whole:
            return nil
        case .nothing:
            return FirstPersonMeshComponent(thirdPersonMesh: mesh, firstPersonMesh: nil)
        case .triangles(let indices):
            var headless = geometry
            headless.indices = indices
            return FirstPersonMeshComponent(thirdPersonMesh: mesh,
                                            firstPersonMesh: try meshResource(geometry: headless,
                                                                              skeleton: skeleton,
                                                                              jointInfluences: jointInfluences))
        }
    }

    /// Widens the bounding box RealityKit culls `passEntity` by, so a geometry
    /// modifier pushing vertices outward is not culled while still on screen,
    /// and tells the modifier how much room it got. The mesh's own radius stands
    /// in for a budget, since mesh-space travel is unknown before the entity is
    /// in a scene.
    private func grantBoundsBudget(to passEntity: ModelEntity,
                                   mesh: MeshResource,
                                   applying applyBudget: (any Material, Float) -> any Material) {
        guard var component = passEntity.components[ModelComponent.self] else { return }
        let budget = mesh.bounds.boundingRadius
        component.boundsMargin = budget
        component.materials = component.materials.map { applyBudget($0, budget) }
        passEntity.components.set(component)
    }

    /// The UV set the meshes rendering `index` carry, and whether the material's
    /// textures disagree about it. Custom meshes carry a single UV channel, so
    /// the core material's first UV-accessed texture decides it.
    func resolvedTexCoord(withMaterialIndex index: Int) -> (selected: Int, isMixed: Bool) {
        if let cached = materialTexCoordCache[index] { return cached }
        guard let gltfMaterial = try? gltf.load(\.materials, at: index) else { return (0, false) }
        let textures = sampledTextures(of: gltfMaterial)
        let resolved = (selected: textures.first?.texCoord ?? 0,
                        isMixed: textures.contains { $0.texCoord != textures.first?.texCoord })
        materialTexCoordCache[index] = resolved
        return resolved
    }

    /// A shader sampling any other set renders through this one.
    func selectedTexCoord(withMaterialIndex index: Int) -> Int {
        resolvedTexCoord(withMaterialIndex: index).selected
    }

    /// Whether the material samples a normal map, which is what decides whether
    /// a primitive without `TANGENT` needs a tangent basis generating. The MToon
    /// descriptor is asked first because VRM 0.x carries its normal map in
    /// Unity's `_BumpMap`.
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

    /// Builds, or returns the cached, materials for one glTF material. The
    /// single place "what does this material render as" is decided.
    func shadedMaterial(withMaterialIndex index: Int) throws -> GLTFShadedMaterial {
        if let cached = try entityData.load(\.materials, index: index) { return cached }
        defer { standardMaterialCache.removeValue(forKey: index) }
        // Resolving the material is not shading it: an index the document does not
        // hold fails the load rather than reaching a fallback.
        let context = try makeMaterialShaderContext(withMaterialIndex: index)
        let shaded: GLTFShadedMaterial
        do {
            shaded = try shadeMaterial(for: context)
        } catch {
            guard let fallback = shadedMaterialFallback(for: context, error: error) else { throw error }
            shaded = fallback
        }
        if entityData.materials.indices.contains(index) {
            entityData.materials[index] = shaded
        }
        return shaded
    }

    /// What the shader chain makes of an already resolved material, falling back
    /// to the built-in Unlit / PBR path when no shader claims it.
    private func shadeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial {
        for shader in shaders {
            if let shaded = try shader.makeMaterial(for: context) { return shaded }
        }
        return GLTFShadedMaterial(material: try standardMaterial(for: context))
    }

    /// What to render a material the shader chain could not build as, or nil to
    /// fail the load with the shader's error. ``VRMEntityLoader`` overrides it.
    func shadedMaterialFallback(for context: GLTFMaterialShaderContext,
                                error: any Error) -> GLTFShadedMaterial? { nil }

    func makeMaterialShaderContext(withMaterialIndex index: Int) throws -> GLTFMaterialShaderContext {
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
        return GLTFMaterialShaderContext(loader: self,
                                         materialIndex: index,
                                         material: gltfMaterial,
                                         vrm0MaterialProperty: materialProperty)
    }

    /// The built-in Unlit / PBR path of the glTF core specification, rendering
    /// every material the shader chain leaves unclaimed. Shaders reach it through
    /// ``GLTFMaterialShaderContext/standardMaterial()`` to decorate its result.
    /// Memoized, so inspecting it costs nothing.
    func standardMaterial(for context: GLTFMaterialShaderContext) throws -> Material {
        if let cached = standardMaterialCache[context.materialIndex] { return cached }
        let material = try makeStandardMaterial(for: context)
        standardMaterialCache[context.materialIndex] = material
        return material
    }

    private var standardMaterialCache: [Int: Material] = [:]

    private func makeStandardMaterial(for context: GLTFMaterialShaderContext) throws -> Material {
        let index = context.materialIndex
        let gltfMaterial = context.material
        let materialProperty = context.vrm0MaterialProperty
        let shaderName = materialProperty?.shader.lowercased()
        // Unreadable MToon (an unimplemented spec version) is still MToon, so it
        // takes the same Unlit approximation as a readable one.
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
                // glTF multiplies the sampled channel by its factor, which is
                // what RealityKit's texture-plus-scale pair does.
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

    /// The textures a standard (non-MToon) material samples through mesh UVs, in
    /// the order the glTF material declares them.
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

    /// The `KHR_texture_transform` a material renders with. RealityKit gives a
    /// material one UV transform, so the first UV-accessed texture's wins.
    func selectedUVTransform(withMaterialIndex index: Int,
                             textures: [GLTFSampledTexture]) -> GLTFUVTransform {
        let selected = textures.first?.transform ?? GLTFUVTransform()
        if textures.contains(where: { ($0.transform ?? GLTFUVTransform()) != selected }) {
            logOnce("uvTransform-\(index)", """
                Material \(index) has per-texture KHR_texture_transform values; \
                RealityKit applies the first UV-accessed transform to all of its textures.
                """)
        }
        return selected
    }

    /// Converts `KHR_texture_transform` into RealityKit's `textureCoordinateTransform`.
    /// Only the rotation direction mirrors: offset and scale already act from the
    /// corner the extension measures from.
    private func standardTextureTransform(withMaterialIndex index: Int,
                                          of gltfMaterial: GLTF.Material) -> MaterialParameterTypes.TextureCoordinateTransform {
        let transform = selectedUVTransform(withMaterialIndex: index,
                                            textures: sampledTextures(of: gltfMaterial))
        return MaterialParameterTypes.TextureCoordinateTransform(offset: transform.offset,
                                                                 scale: transform.scale,
                                                                 rotation: -transform.rotation)
    }

    /// What MToon data the material at `index` carries, decoded from the
    /// `VRMC_materials_mtoon` extension or the VRM 0.x material property. The
    /// built-in fallback and tangent generation both read it.
    func mtoonResolution(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor.Resolution {
        if let cached = mtoonResolutionCache[index] {
            return cached
        }
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
        let resolution = MToonMaterialDescriptor.resolve(material: gltfMaterial,
                                                         materialProperty: materialProperty)
        if case .unsupportedVersion(let specVersion) = resolution {
            logOnce("mtoonSpecVersion-\(specVersion)", """
                Material \(index) declares VRMC_materials_mtoon specVersion \(specVersion), which this \
                renderer does not implement, so it renders as an Unlit approximation.
                """)
        }
        mtoonResolutionCache[index] = resolution
        return resolution
    }

    /// The MToon material model describing the material at `index`, or nil when
    /// it carries none this renderer can read.
    func mtoonDescriptor(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor? {
        try mtoonResolution(withMaterialIndex: index).descriptor
    }

    /// The glTF material and, for VRM 0.x, the Unity material property
    /// describing it. Both are array lookups, so neither is cached.
    private func materialSource(withMaterialIndex index: Int) throws -> (GLTF.Material, VRM0.MaterialProperty?) {
        (try gltf.load(\.materials, at: index), vrm0MaterialProperty(atMaterialIndex: index))
    }

    /// VRM 0.x compatibility hook, overridden by ``VRMEntityLoader``.
    func vrm0MaterialProperty(atMaterialIndex index: Int) -> VRM0.MaterialProperty? {
        nil
    }

    /// A fresh mutable runtime state for the material, made by the material on
    /// screen, so the state always describes what is actually drawn.
    func makeAnimatableMaterialState(forMaterialIndex index: Int) -> (any VRMAnimatableMaterialState)? {
        (try? shadedMaterial(withMaterialIndex: index))?.makeAnimatableState?()
    }

    func texture(withTextureIndex index: Int, semantic: TextureResource.Semantic = .color) throws -> TextureResource {
        let key = ImageTextureKey(imageIndex: try gltf.load(\.textures, at: index).source,
                                  semantic: semantic)
        if let cache = textureCache[key] { return cache }
        let cgImage = try image(withImageIndex: key.imageIndex)
        let texture = try TextureResource(image: cgImage, options: .init(semantic: semantic))
        textureCache[key] = texture
        return texture
    }

    func materialTexture(withTextureIndex index: Int,
                         semantic: TextureResource.Semantic = .color) throws -> MaterialParameters.Texture {
        let texture = try texture(withTextureIndex: index, semantic: semantic)
        let sampler = try sampler(withTextureIndex: index)
        return MaterialParameters.Texture(texture, sampler: sampler)
    }

    func sampler(withTextureIndex index: Int) throws -> MaterialParameters.Texture.Sampler {
        let samplerIndex = try gltf.load(\.textures, at: index).sampler
        if let cache = samplerCache[samplerIndex] {
            return cache
        }
        let descriptor = MTLSamplerDescriptor()
        applySampler(try samplerIndex.map { try gltf.load(\.samplers, at: $0) }, to: descriptor)
        let sampler = MaterialParameters.Texture.Sampler(descriptor)
        samplerCache[samplerIndex] = sampler
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

    func image(withImageIndex index: Int) throws -> CGImage {
        if let cache = try entityData.load(\.images, index: index) { return cache }
        let image = try document.image(at: index)
        entityData.images[index] = image
        return image
    }

    /// The normal map a material samples, with `normalTexture.scale` applied.
    private func normalTextureParameter(_ info: GLTF.Material.NormalTextureInfo) throws -> MaterialParameters.Texture {
        guard info.scale != 1 else {
            return try materialTexture(withTextureIndex: info.index, semantic: .normal)
        }
        return try bakedTexture(withTextureIndex: info.index,
                                factor: info.scale,
                                semantic: .normal,
                                bake: scaledNormalImage)
    }

    /// The occlusion map a material samples, with `occlusionTexture.strength`
    /// applied. Occlusion is linear data, so `.raw`: `.color` would apply an
    /// sRGB-to-linear conversion.
    private func occlusionTextureParameter(_ info: GLTF.Material.OcclusionTextureInfo) throws -> MaterialParameters.Texture {
        guard info.strength != 1 else {
            return try materialTexture(withTextureIndex: info.index, semantic: .raw)
        }
        return try bakedTexture(withTextureIndex: info.index,
                                factor: info.strength,
                                semantic: .raw,
                                bake: weakenedOcclusionImage)
    }

    /// A texture with one of glTF's scalar factors baked into its pixels, built
    /// once per texture and factor: RealityKit's normal and ambient-occlusion
    /// parameters carry no scalar beside the texture.
    private func bakedTexture(withTextureIndex index: Int,
                              factor: Float,
                              semantic: TextureResource.Semantic,
                              bake: (CGImage, Float) throws -> CGImage) throws -> MaterialParameters.Texture {
        let key = BakedTextureKey(imageIndex: try gltf.load(\.textures, at: index).source,
                                  factor: factor,
                                  semantic: semantic)
        let resource: TextureResource
        if let cached = bakedTextureCache[key] {
            resource = cached
        } else {
            let cgImage = try image(withImageIndex: key.imageIndex)
            resource = try TextureResource(image: try bake(cgImage, factor),
                                           options: .init(semantic: semantic))
            bakedTextureCache[key] = resource
        }
        return MaterialParameters.Texture(resource, sampler: try sampler(withTextureIndex: index))
    }

    /// glTF scales a sampled normal's x and y by `normalTexture.scale` and
    /// renormalizes it, which the map can carry itself.
    func scaledNormalImage(_ image: CGImage, scale: Float) throws -> CGImage {
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

    /// glTF blends sampled occlusion toward "no occlusion" by
    /// `occlusionTexture.strength`, so a strength of 0 lights the surface as if
    /// the map were absent.
    func weakenedOcclusionImage(_ image: CGImage, strength: Float) throws -> CGImage {
        try rewritingPixels(of: image) { pixels, pixelCount in
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                // glTF keeps occlusion in the red channel; the others follow it so
                // the result reads the same whichever channel is sampled.
                let occlusion = 1 + strength * (Float(pixels[offset]) / 255 - 1)
                let value = UInt8(clamping: Int((occlusion * 255).rounded()))
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
    }

    private func rewritingPixels(of image: CGImage,
                                 _ rewrite: (UnsafeMutablePointer<UInt8>, Int) -> Void) throws -> CGImage {
        try withRGBA8Pixels(of: image) { context, pixels, pixelCount in
            rewrite(pixels, pixelCount)
            return try context.makeImage() ??? .dataInconsistent("failed to create CGImage")
        }
    }

    /// Draws `image` into a freshly allocated 8-bit RGBA buffer and hands `body`
    /// that buffer, its pixel count and the context behind it, all valid only
    /// for the duration of the call.
    private func withRGBA8Pixels<Result>(
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
        let imageIndex = try gltf.load(\.textures, at: index).source
        let resources: (metal: TextureResource, rough: TextureResource)
        if let cache = metallicRoughnessCache[imageIndex] {
            resources = cache
        } else {
            let textures = try createMetallicRoughnessTextures(from: try image(withImageIndex: imageIndex))
            metallicRoughnessCache[imageIndex] = textures
            resources = textures
        }
        let sampler = try sampler(withTextureIndex: index)
        return (MaterialParameters.Texture(resources.metal, sampler: sampler),
                MaterialParameters.Texture(resources.rough, sampler: sampler))
    }

    /// glTF packs roughness in the green channel and metalness in the blue one of
    /// a single texture; RealityKit samples a texture of its own for each.
    private func createMetallicRoughnessTextures(
        from image: CGImage
    ) throws -> (metal: TextureResource, rough: TextureResource) {
        let images = try metallicRoughnessImages(from: image)

        // Metallic / roughness are linear data; .color would apply an sRGB conversion.
        return (try TextureResource(image: images.metal, options: .init(semantic: .raw)),
                try TextureResource(image: images.rough, options: .init(semantic: .raw)))
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

    private func makeJointInfluences(joints: [SIMD4<UInt32>],
                                     weights: [SIMD4<Float>],
                                     vertexCount: Int,
                                     jointIndexRemap remap: [Int]) throws -> MeshResource.JointInfluences {
        guard joints.count == weights.count else {
            throw VRMError._dataInconsistent("JOINTS_0 and WEIGHTS_0 counts do not match")
        }
        guard joints.count == vertexCount else {
            throw VRMError._dataInconsistent("joint influence count \(joints.count) does not match vertex count \(vertexCount)")
        }

        var influences: [MeshJointInfluence] = []
        influences.reserveCapacity(joints.count * 4)
        func remapped(_ jointIndex: UInt32) throws -> Int {
            guard remap.indices.contains(Int(jointIndex)) else {
                throw VRMError._dataInconsistent(
                    "joint index \(jointIndex) is out of range for \(remap.count) skin joints"
                )
            }
            return remap[Int(jointIndex)]
        }
        for i in 0..<joints.count {
            let joint = joints[i]
            var w0 = weights[i].x
            var w1 = weights[i].y
            var w2 = weights[i].z
            var w3 = weights[i].w
            let sum = w0 + w1 + w2 + w3
            if sum > 0 {
                w0 /= sum
                w1 /= sum
                w2 /= sum
                w3 /= sum
            }
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.x), weight: w0))
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.y), weight: w1))
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.z), weight: w2))
            influences.append(MeshJointInfluence(jointIndex: try remapped(joint.w), weight: w3))
        }

        let buffer = MeshBuffer(influences)
        return MeshResource.JointInfluences(influences: buffer, influencesPerVertex: 4)
    }

    /// The skin at `index` resolved for RealityKit. Its skeleton and its joint
    /// remap come out of the same ordering pass, so they are cached together.
    func skin(withSkinIndex index: Int) throws -> EntityData.Skin {
        if let cache = try entityData.load(\.skins, index: index) { return cache }
        let skin = try gltf.load(\.skins, at: index)
        let nodes = try gltf.load(\.nodes)
        let (parentIndices, order, remap) = computeSkinJointOrdering(skin: skin)

        // glTF defines an absent inverseBindMatrices as identity per joint, but a
        // present one has to cover every joint.
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

        let resolved = EntityData.Skin(skeleton: MeshResource.Skeleton(id: "skin_\(index)", joints: joints),
                                       jointIndexRemap: remap)
        entityData.skins[index] = resolved
        return resolved
    }

    private func computeSkinJointOrdering(skin: GLTF.Skin) -> (parentIndices: [Int?], order: [Int], remap: [Int]) {
        let jointNodeIndices = skin.joints
        let jointIndexMap = Dictionary(uniqueKeysWithValues: jointNodeIndices.enumerated().map { ($0.element, $0.offset) })
        var parentIndices: [Int?] = Array(repeating: nil, count: jointNodeIndices.count)
        for (i, nodeIndex) in jointNodeIndices.enumerated() {
            // The validated hierarchy is a forest, so walking up terminates.
            var current = nodeIndex
            while let parent = nodeHierarchy?.parent(at: current) {
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

        // The validated hierarchy is a forest, so visiting every root reaches
        // every joint.
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

    private func meshResource(geometry: GLTFPrimitiveGeometry,
                              skeleton: MeshResource.Skeleton?,
                              jointInfluences: MeshResource.JointInfluences?) throws -> MeshResource {
        var part = MeshResource.Part(id: UUID().uuidString, materialIndex: 0)
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
        if let skeleton, let jointInfluences {
            part.skeletonID = skeleton.id
            part.jointInfluences = jointInfluences
        }

        let modelID = UUID().uuidString
        let model = MeshResource.Model(id: modelID, parts: [part])

        var models = MeshModelCollection()
        _ = models.insert(model)

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

        return try MeshResource.generate(from: contents)
    }

    /// Binds the skinned models of a freshly cloned mesh to this scene's joints.
    private func registerSkinBindings(in root: Entity) throws {
        guard let currentEntity else { return }
        for modelEntity in root.modelEntitiesInHierarchy {
            guard let skinIndex = modelEntity.components[GLTFSkinIndexComponent.self]?.skinIndex else {
                continue
            }
            let jointNodes = try gltf.load(\.skins, at: skinIndex).joints
            let jointsInSkinOrder = try jointNodes.map { try node(withNodeIndex: $0) }
            // The skeleton reorders the joints parents-first, and the pose is
            // written in the skeleton's order.
            let skin = try skin(withSkinIndex: skinIndex)
            var jointEntities = jointsInSkinOrder
            for (oldIndex, newIndex) in skin.jointIndexRemap.enumerated() {
                jointEntities[newIndex] = jointsInSkinOrder[oldIndex]
            }
            currentEntity.registerSkinBinding(modelEntity: modelEntity,
                                              skeleton: skin.skeleton,
                                              jointEntities: jointEntities)
        }
    }

    private func registerMaterialBindings(in root: Entity) {
        guard let currentEntity else { return }
        for modelEntity in root.modelEntitiesInHierarchy {
            guard let materialIndex = modelEntity.components[GLTFMaterialIndexComponent.self]?.materialIndex else {
                continue
            }
            currentEntity.registerMaterialBinding(modelEntity: modelEntity,
                                                  materialIndex: materialIndex,
                                                  loader: self)
        }
    }

    /// glTF's default material for a primitive that names none: lit, white, and
    /// fully metallic and rough.
    func defaultMaterial() -> Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white)
        material.metallic = .init(floatLiteral: 1.0)
        material.roughness = .init(floatLiteral: 1.0)
        return material
    }

}

#endif
