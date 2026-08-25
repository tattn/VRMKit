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
    private let accessors: PackedAccessorCache

    /// Name given to the loaded root entity. Subclasses set it from model metadata.
    var entityName: String?
    weak var currentEntity: GLTFEntity?
    static let gltfLogger = Logger(subsystem: "dev.tattn.VRMKit", category: "glTF")

    /// The document's node parents, built and validated once by
    /// ``validateStructure()`` and read by everything that walks upwards.
    private var nodeHierarchy: GLTFNodeHierarchy?
    private var loggedLimitations: Set<String> = []
    private var materialTexCoordCache: [Int: (selected: Int, isMixed: Bool)] = [:]
    private var morphTargetCounts: [Int: Int] = [:]

    func logOnce(_ key: String, _ message: @autoclosure () -> String) {
        guard loggedLimitations.insert(key).inserted else { return }
        let text = message()
        Self.gltfLogger.warning("\(text, privacy: .public)")
    }

    /// Textures decoded per semantic: RealityKit bakes the semantic into the
    /// resource, so one glTF texture read as color and as a normal map is two.
    private var textureCacheBySemantic: [TextureResource.Semantic: [Int: TextureResource]] = [:]
    private var metallicRoughnessCache: [Int: (metal: TextureResource, rough: TextureResource)] = [:]
    /// One glTF texture read through a scalar factor baked into its pixels.
    private struct BakedTextureKey: Hashable {
        let textureIndex: Int
        let factor: Float
        let semantic: TextureResource.Semantic
    }

    private var bakedTextureCache: [BakedTextureKey: TextureResource] = [:]
    private var samplerCache: [Int: MaterialParameters.Texture.Sampler] = [:]
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

    /// Loads the document's default scene.
    ///
    /// - Throws: when the glTF names no default `scene`; such an asset is a
    ///   library of nodes, so the caller picks a scene with
    ///   ``loadEntity(withSceneIndex:)``.
    public func loadEntity() throws -> GLTFEntity {
        let scene = try gltf.scene ??? ._dataInconsistent("this glTF has no default scene")
        return try loadEntity(withSceneIndex: scene)
    }

    /// Loads one scene of the glTF as its own entity graph. Every call builds a
    /// new graph, even for the same scene, while resources are reused.
    public func loadEntity(withSceneIndex index: Int) throws -> GLTFEntity {
        try validateRequiredExtensions()
        try validateStructure()
        let gltfScene = try gltf.load(\.scenes, at: index)
        entityData.beginScene()

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
        // A skin binding is registered while the graph around it is still being
        // built, so the rest pose is only solvable once the graph is complete.
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
    ///
    /// Not an override point outside this module: claiming an extension this
    /// renderer cannot draw would only silence the check that rejects it.
    public var supportedRequiredExtensions: Set<String> {
        var extensions: Set<String> = [GLTFExtension.materialsUnlit.rawValue,
                                       GLTFExtension.textureTransform.rawValue]
        for shader in shaders {
            extensions.formUnion(shader.supportedRequiredExtensions)
        }
        return extensions
    }

    /// Fails the load when the file requires an extension this renderer does not
    /// implement, as the glTF spec demands, or leans on a required extension past
    /// what this renderer implements of it.
    func validateRequiredExtensions() throws {
        if let unsupported = unsupportedRequiredExtensions().first {
            throw VRMError._notSupported("this glTF requires the \(unsupported) extension")
        }
        if enforcesRequiredExtension(GLTFExtension.textureTransform.rawValue) {
            try validateTextureTransformsAreRenderable()
        }
    }

    /// RealityKit gives a material one UV transform, and its mesh one UV set, so
    /// `KHR_texture_transform` is only fully implemented while a material's
    /// textures agree on both. An asset that merely *uses* the extension renders
    /// through the first UV-accessed texture's set and transform and logs the
    /// approximation; one that *requires* it is rejected instead.
    ///
    /// This covers the textures of the core glTF material. A shader sampling
    /// textures the core material does not name, such as MToon's shade and rim
    /// maps, checks those itself against the same limits.
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

    /// Whether the document declares itself undrawable without `name` *and* this
    /// load honors that declaration. It is the signal for a shader to fail a
    /// material rather than draw an approximation of it.
    ///
    /// ``VRMEntityLoader`` renders a VRM with whatever it can build, so it
    /// answers false even for a listed extension, matching its
    /// ``VRMEntityLoader/validateRequiredExtensions()``.
    func enforcesRequiredExtension(_ name: String) -> Bool {
        gltf.extensionsRequired?.contains(name) == true
    }

    /// `extensionsRequired` entries outside ``supportedRequiredExtensions``.
    func unsupportedRequiredExtensions() -> [String] {
        let supported = supportedRequiredExtensions
        return (gltf.extensionsRequired ?? []).filter { !supported.contains($0) }
    }

    /// Validates, once per document, the node graph and skins the rest of the
    /// loader takes for granted.
    private func validateStructure() throws {
        guard nodeHierarchy == nil else { return }
        nodeHierarchy = try GLTFNodeHierarchy.validatingStructure(of: gltf)
    }

    func node(withNodeIndex index: Int) throws -> Entity {
        if let cache = try entityData.load(\.nodes, index: index) { return cache }

        let entity = Entity()
        // A skinned mesh may sit below one of its own joints, whose entity its
        // skin binding then asks for mid-build. Publishing the entity before its
        // subtree exists ends that recursion.
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
            let meshEntity = try mesh(withMeshIndex: meshIndex, skinIndex: gltfNode.skin)
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
    /// weights array driving it holds one weight for.
    ///
    /// A primitive declaring no target of its own does not take part: where a VRM
    /// leaves them off, ``resolvedPrimitives(of:)`` has filled in the shared ones.
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
    /// `mesh.weights`, so the first frame renders correctly without animation.
    ///
    /// Both are sized by the mesh's morph target count; another length means the
    /// file and this renderer disagree about what the weights stand for.
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
    func mesh(withMeshIndex index: Int, skinIndex: Int?) throws -> Entity {
        // A mesh is built once per skin it is used with and cloned per node: the
        // clones share the `MeshResource` and carry their own pose and weights.
        let meshEntity = try meshTemplate(withMeshIndex: index, skinIndex: skinIndex).clone(recursive: true)
        try registerSkinBindings(in: meshEntity)
        registerMaterialBindings(in: meshEntity)
        entityData.sceneMeshes[index, default: []].append(meshEntity)
        return meshEntity
    }

    /// The clone source for one (mesh, skin) pair, which never joins a scene itself.
    private func meshTemplate(withMeshIndex index: Int, skinIndex: Int?) throws -> Entity {
        let key = EntityData.MeshTemplateKey(meshIndex: index, skinIndex: skinIndex)
        if let cache = entityData.meshTemplates[key] { return cache }
        let template = try makeMeshEntity(withMeshIndex: index, skinIndex: skinIndex)
        entityData.meshTemplates[key] = template
        return template
    }

    private func makeMeshEntity(withMeshIndex index: Int, skinIndex: Int?) throws -> Entity {
        let gltfMesh = try gltf.load(\.meshes, at: index)
        let meshEntity = Entity()
        meshEntity.name = gltfMesh.name ?? "mesh_\(index)"

        for primitive in resolvedPrimitives(of: gltfMesh) {
            if let primitiveEntity = try modelEntity(withPrimitive: primitive,
                                                     skinIndex: skinIndex,
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

    private func modelEntity(withPrimitive primitive: GLTF.Mesh.Primitive,
                             skinIndex: Int?,
                             meshName: String) throws -> Entity? {
        guard supportsTriangles(primitive.mode) else {
            logOnce("primitiveMode-\(primitive.mode)", """
                A \(primitive.mode) primitive was skipped; RealityKit meshes render triangles only.
                """)
            return nil
        }

        let attributes = primitive.attributes.rawValue
        guard let positionIndex = attributes[.POSITION] else {
            throw VRMError._dataInconsistent("POSITION attribute is missing")
        }

        let positions = try vector3s(positionIndex)

        // glTF requires every vertex attribute to hold as many elements as POSITION.
        func vertexAttribute<Element>(_ key: GLTF.Mesh.Primitive.AttributeKey,
                                      _ read: (Int) throws -> [Element]) throws -> [Element]? {
            guard let accessorIndex = attributes[key] else { return nil }
            let values = try read(accessorIndex)
            guard values.count == positions.count else {
                throw VRMError._dataInconsistent(
                    "\(key) has \(values.count) elements but POSITION has \(positions.count)"
                )
            }
            return values
        }

        if attributes[.COLOR_0] != nil {
            logOnce("COLOR_0", "COLOR_0 vertex colors are not applied; the mesh parts this renderer builds carry no vertex-color channel. The primitive renders without them.")
        }

        let normals = try vertexAttribute(.NORMAL, vector3s)
        // A primitive without NORMAL is flat shaded, and glTF has its TANGENTs
        // ignored along with it: they were authored for the normals it omits.
        let rawTangents = normals == nil ? nil : try vertexAttribute(.TANGENT, vector4s)
        let texcoords = try vertexAttribute(texcoordAttributeKey(forMaterialIndex: primitive.material,
                                                                 attributes: attributes),
                                            vector2s)
        // glTF requires every primitive of a skinned mesh to carry both skinning
        // attributes, so a missing one is a malformed asset, not an unskinned mesh.
        let skinning: (joints: [SIMD4<UInt32>], weights: [SIMD4<Float>], remap: [Int])? = try skinIndex.map { skinIndex in
            guard let joints = try vertexAttribute(.JOINTS_0, jointIndices),
                  let weights = try vertexAttribute(.WEIGHTS_0, jointWeights) else {
                throw VRMError._dataInconsistent(
                    "a primitive of a mesh skinned by skin \(skinIndex) has no JOINTS_0 / WEIGHTS_0 attribute"
                )
            }
            return (joints, weights, try skin(withSkinIndex: skinIndex).jointIndexRemap)
        }
        // Only POSITION morphs: RealityKit blend shapes have no NORMAL / TANGENT channel.
        var targetOffsets: [[SIMD3<Float>]] = []
        if let targets = primitive.targets, !targets.isEmpty {
            targetOffsets.reserveCapacity(targets.count)
            for target in targets {
                if let positionAccessor = target[.POSITION] {
                    let offsets = try vector3s(positionAccessor)
                    guard offsets.count == positions.count else {
                        throw VRMError._dataInconsistent("blend shape target count \(offsets.count) does not match vertex count \(positions.count)")
                    }
                    targetOffsets.append(offsets)
                } else {
                    targetOffsets.append(Array(repeating: .zero, count: positions.count))
                }
            }
        }

        var indexData: [UInt32]
        if let indicesAccessor = primitive.indices {
            indexData = try indexValues(indicesAccessor)
        } else {
            indexData = (0..<positions.count).map { UInt32($0) }
        }
        indexData = try triangulatedIndices(for: primitive.mode, indices: indexData)
        if let maxIndex = indexData.max(), Int(maxIndex) >= positions.count {
            throw VRMError._dataInconsistent(
                "triangle index \(maxIndex) is out of range for \(positions.count) vertices"
            )
        }

        var finalPositions = positions
        var finalTexcoords = texcoords ?? []
        var finalJoints = skinning?.joints ?? []
        var finalWeights = skinning?.weights ?? []
        if normals == nil {
            // Flat shading needs a normal per triangle corner, so every attribute
            // is expanded along the triangle list and the index buffer with it.
            let corners = indexData
            func expanded<Element>(_ values: [Element]) -> [Element] {
                values.isEmpty ? values : corners.map { values[Int($0)] }
            }
            finalPositions = expanded(finalPositions)
            finalTexcoords = expanded(finalTexcoords)
            finalJoints = expanded(finalJoints)
            finalWeights = expanded(finalWeights)
            targetOffsets = targetOffsets.map(expanded)
            indexData = Array(0..<UInt32(finalPositions.count))
        }
        let finalNormals = normals ?? flatNormals(positions: finalPositions)
        let tangentFrame = tangentFrame(rawTangents: rawTangents,
                                        positions: finalPositions,
                                        normals: finalNormals,
                                        texcoords: finalTexcoords,
                                        indices: indexData,
                                        materialIndex: primitive.material)

        let shaded = try primitive.material.map { try primitiveShadedMaterial(withMaterialIndex: $0) }
            ?? GLTFShadedMaterial(material: defaultMaterial())

        // A skinned primitive binds its vertex influences to the skin's skeleton;
        // an unskinned one has neither.
        var skinSkeleton: MeshResource.Skeleton?
        var jointInfluences: MeshResource.JointInfluences?
        if let skinIndex, let skinning {
            jointInfluences = try makeJointInfluences(joints: finalJoints,
                                                      weights: finalWeights,
                                                      vertexCount: finalPositions.count,
                                                      jointIndexRemap: skinning.remap)
            skinSkeleton = try skin(withSkinIndex: skinIndex).skeleton
        }
        let mesh = try meshResource(positions: finalPositions,
                                    normals: finalNormals,
                                    tangentFrame: tangentFrame,
                                    texcoords: finalTexcoords,
                                    indices: indexData,
                                    blendShapeOffsets: targetOffsets,
                                    skeleton: skinSkeleton,
                                    jointInfluences: jointInfluences)

        let blendShapeMapping = targetOffsets.isEmpty ? nil : BlendShapeWeightsMapping(meshResource: mesh)

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
            return container
        }
        return modelEntity
    }

    /// Widens the bounding box RealityKit culls `passEntity` by, so a pass whose
    /// geometry modifier pushes vertices outward is not culled while part of it
    /// is still on screen, and tells the modifier how much room it got. The
    /// mesh's own radius stands in for a budget, since how far the vertices
    /// travel does not convert into mesh space before the entity is in a scene.
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
    private func resolvedTexCoord(withMaterialIndex index: Int) -> (selected: Int, isMixed: Bool) {
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

    /// The attribute this primitive's mesh reads its one UV channel from.
    private func texcoordAttributeKey(forMaterialIndex materialIndex: Int?,
                                      attributes: [GLTF.Mesh.Primitive.AttributeKey: Int]) -> GLTF.Mesh.Primitive.AttributeKey {
        guard let materialIndex else { return .TEXCOORD_0 }
        let resolved = resolvedTexCoord(withMaterialIndex: materialIndex)
        let selected = resolved.selected
        guard selected != 0 else { return .TEXCOORD_0 }
        let isMixed = resolved.isMixed
        let isAvailable = selected == 1 && attributes[.TEXCOORD_1] != nil
        if isMixed || !isAvailable {
            logOnce("texCoord-\(materialIndex)", """
                Material \(materialIndex) samples UV set \(selected)\(isMixed ? " among others" : ""); \
                RealityKit meshes carry one UV channel, so \
                \(isAvailable ? "that set is used for every texture" : "TEXCOORD_0 is used instead").
                """)
        }
        return isAvailable ? .TEXCOORD_1 : .TEXCOORD_0
    }

    private func supportsTriangles(_ mode: GLTF.Mesh.Primitive.Mode) -> Bool {
        switch mode {
        case .TRIANGLES, .TRIANGLE_STRIP, .TRIANGLE_FAN:
            return true
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP:
            return false
        }
    }

    private func triangulatedIndices(for mode: GLTF.Mesh.Primitive.Mode,
                                     indices: [UInt32]) throws -> [UInt32] {
        switch mode {
        case .TRIANGLES:
            guard !indices.isEmpty, indices.count.isMultiple(of: 3) else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLES primitive needs a non-zero multiple of 3 indices, but has \(indices.count)"
                )
            }
            return indices
        case .TRIANGLE_STRIP:
            guard indices.count >= 3 else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLE_STRIP primitive needs at least 3 indices, but has \(indices.count)"
                )
            }
            var result: [UInt32] = []
            result.reserveCapacity((indices.count - 2) * 3)
            for i in 0..<(indices.count - 2) {
                let i0 = indices[i]
                let i1 = indices[i + 1]
                let i2 = indices[i + 2]
                if i.isMultiple(of: 2) {
                    result.append(contentsOf: [i0, i1, i2])
                } else {
                    result.append(contentsOf: [i1, i0, i2])
                }
            }
            return result
        case .TRIANGLE_FAN:
            guard indices.count >= 3 else {
                throw VRMError._dataInconsistent(
                    "a TRIANGLE_FAN primitive needs at least 3 indices, but has \(indices.count)"
                )
            }
            let base = indices[0]
            var result: [UInt32] = []
            result.reserveCapacity((indices.count - 2) * 3)
            for i in 1..<(indices.count - 1) {
                result.append(contentsOf: [base, indices[i], indices[i + 1]])
            }
            return result
        case .POINTS, .LINES, .LINE_LOOP, .LINE_STRIP:
            // Filtered out by supportsTriangles() before the indices are read.
            throw VRMError._notSupported("\(mode) primitives have no triangles")
        }
    }

    /// The materials a primitive renders with. ``VRMEntityLoader`` overrides it
    /// to keep rendering a model whose material this renderer cannot build.
    func primitiveShadedMaterial(withMaterialIndex index: Int) throws -> GLTFShadedMaterial {
        try shadedMaterial(withMaterialIndex: index)
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
        let context = try makeMaterialShaderContext(withMaterialIndex: index)
        for shader in shaders {
            if let shaded = try shader.makeMaterial(for: context) {
                cacheShadedMaterial(shaded, withMaterialIndex: index)
                return shaded
            }
        }
        let shaded = GLTFShadedMaterial(material: try standardMaterial(for: context))
        cacheShadedMaterial(shaded, withMaterialIndex: index)
        return shaded
    }

    /// Records what a material renders as, so the shader chain runs at most once
    /// per material. ``VRMEntityLoader`` also caches the material it falls back
    /// to when the chain fails.
    func cacheShadedMaterial(_ shaded: GLTFShadedMaterial, withMaterialIndex index: Int) {
        guard entityData.materials.indices.contains(index) else { return }
        entityData.materials[index] = shaded
    }

    func makeMaterialShaderContext(withMaterialIndex index: Int) throws -> GLTFMaterialShaderContext {
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
        return GLTFMaterialShaderContext(loader: self,
                                         materialIndex: index,
                                         material: gltfMaterial,
                                         vrm0MaterialProperty: materialProperty)
    }

    /// The built-in Unlit / PBR path of the glTF core specification, rendering
    /// every material the shader chain leaves unclaimed. Shaders reach it
    /// through ``GLTFMaterialShaderContext/standardMaterial()`` to decorate its
    /// result, and it is memoized so inspecting it costs nothing.
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
    ///
    /// Only the rotation direction mirrors, since offset and scale already act
    /// from the corner the extension measures from, which is what
    /// `TextureTransformRenderingTests` checks against what RealityKit draws.
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
    /// loader keeps it even though ``MToonShader`` does the MToon rendering,
    /// since the built-in fallback and tangent generation both read it.
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
    /// describing it, resolved once per material index.
    private func materialSource(withMaterialIndex index: Int) throws -> (GLTF.Material, VRM0.MaterialProperty?) {
        if let cached = materialSourceCache[index] { return cached }
        let gltfMaterial = try gltf.load(\.materials, at: index)
        let source = (gltfMaterial, vrm0MaterialProperty(atMaterialIndex: index))
        materialSourceCache[index] = source
        return source
    }

    private var materialSourceCache: [Int: (GLTF.Material, VRM0.MaterialProperty?)] = [:]

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
        if let cache = textureCacheBySemantic[semantic]?[index] { return cache }
        let gltfTexture = try gltf.load(\.textures, at: index)
        let image = try image(withImageIndex: gltfTexture.source)
        let cgImage = try image.cgImage ??? .dataInconsistent("failed to load cgImage")
        let texture = try TextureResource(image: cgImage, options: .init(semantic: semantic))
        textureCacheBySemantic[semantic, default: [:]][index] = texture
        return texture
    }

    func materialTexture(withTextureIndex index: Int,
                         semantic: TextureResource.Semantic = .color) throws -> MaterialParameters.Texture {
        let texture = try texture(withTextureIndex: index, semantic: semantic)
        let sampler = try sampler(withTextureIndex: index)
        return MaterialParameters.Texture(texture, sampler: sampler)
    }

    func sampler(withTextureIndex index: Int) throws -> MaterialParameters.Texture.Sampler {
        if let cache = samplerCache[index] {
            return cache
        }
        let descriptor = MTLSamplerDescriptor()
        applySampler(try gltfSampler(withTextureIndex: index), to: descriptor)
        let sampler = MaterialParameters.Texture.Sampler(descriptor)
        samplerCache[index] = sampler
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

    func image(withImageIndex index: Int) throws -> VRMImage {
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
    /// once per texture and factor. RealityKit's normal and ambient-occlusion
    /// parameters carry no scalar beside the texture, so a factor other than
    /// the neutral 1 has nowhere else to go.
    private func bakedTexture(withTextureIndex index: Int,
                              factor: Float,
                              semantic: TextureResource.Semantic,
                              bake: (CGImage, Float) throws -> CGImage) throws -> MaterialParameters.Texture {
        let key = BakedTextureKey(textureIndex: index, factor: factor, semantic: semantic)
        let resource: TextureResource
        if let cached = bakedTextureCache[key] {
            resource = cached
        } else {
            let gltfTexture = try gltf.load(\.textures, at: index)
            let image = try image(withImageIndex: gltfTexture.source)
            let cgImage = try image.cgImage ??? .dataInconsistent("failed to load cgImage")
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
    /// that buffer, its pixel count and the context behind it. All three live
    /// only for the call.
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
        let resources: (metal: TextureResource, rough: TextureResource)
        if let cache = metallicRoughnessCache[index] {
            resources = cache
        } else {
            let gltfTexture = try gltf.load(\.textures, at: index)
            let image = try image(withImageIndex: gltfTexture.source)
            let textures = try createMetallicRoughnessTextures(from: image)
            metallicRoughnessCache[index] = textures
            resources = textures
        }
        let sampler = try sampler(withTextureIndex: index)
        return (MaterialParameters.Texture(resources.metal, sampler: sampler),
                MaterialParameters.Texture(resources.rough, sampler: sampler))
    }

    /// glTF packs roughness in the green channel and metalness in the blue one of
    /// a single texture; RealityKit samples a texture of its own for each.
    private func createMetallicRoughnessTextures(from uiImage: VRMImage) throws -> (metal: TextureResource, rough: TextureResource) {
        guard let image = uiImage.cgImage else {
            throw VRMError._dataInconsistent("failed to load cgImage")
        }

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

    /// UVs arrive V-flipped: glTF's origin is top-left, RealityKit's is bottom-left.
    private func vector2s(_ accessorIndex: Int) throws -> [SIMD2<Float>] {
        try accessors.floatElements(at: accessorIndex, type: .VEC2) {
            SIMD2<Float>($0(0), 1.0 - $0(1))
        }
    }

    private func vector3s(_ accessorIndex: Int) throws -> [SIMD3<Float>] {
        try accessors.floatElements(at: accessorIndex, type: .VEC3) {
            SIMD3<Float>($0(0), $0(1), $0(2))
        }
    }

    private func vector4s(_ accessorIndex: Int) throws -> [SIMD4<Float>] {
        try accessors.floatElements(at: accessorIndex, type: .VEC4) {
            SIMD4<Float>($0(0), $0(1), $0(2), $0(3))
        }
    }

    private func indexValues(_ accessorIndex: Int) throws -> [UInt32] {
        try accessors.accessor(at: accessorIndex).unsignedElements(.SCALAR) { $0(0) }
    }

    /// JOINTS_n as glTF defines it: unsigned byte or short indices into the skin.
    private func jointIndices(_ accessorIndex: Int) throws -> [SIMD4<UInt32>] {
        let packed = try accessors.accessor(at: accessorIndex)
        switch packed.componentType {
        case .unsignedByte, .unsignedShort:
            return try packed.unsignedElements(.VEC4) {
                SIMD4<UInt32>($0(0), $0(1), $0(2), $0(3))
            }
        case .byte, .short, .unsignedInt, .float:
            throw VRMError._dataInconsistent(
                "JOINTS_0 must use unsigned byte or short components, not \(packed.componentType)"
            )
        }
    }

    /// WEIGHTS_n as glTF defines it: float, or normalized unsigned byte / short.
    private func jointWeights(_ accessorIndex: Int) throws -> [SIMD4<Float>] {
        let packed = try accessors.accessor(at: accessorIndex)
        switch packed.componentType {
        case .float:
            return try vector4s(accessorIndex)
        case .unsignedByte, .unsignedShort:
            guard packed.normalized else {
                throw VRMError._dataInconsistent(
                    "WEIGHTS_0 with \(packed.componentType) components must be normalized"
                )
            }
            return try vector4s(accessorIndex)
        case .byte, .short, .unsignedInt:
            throw VRMError._dataInconsistent(
                "WEIGHTS_0 must use float or normalized unsigned byte / short components, not \(packed.componentType)"
            )
        }
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
    private func skin(withSkinIndex index: Int) throws -> EntityData.Skin {
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

        // `validateStructure()` has proven the hierarchy to be a forest, so the
        // joints form one too and visiting every root reaches all of them.
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

    private func meshResource(positions: [SIMD3<Float>],
                              normals: [SIMD3<Float>],
                              tangentFrame: TangentFrame,
                              texcoords: [SIMD2<Float>],
                              indices: [UInt32],
                              blendShapeOffsets: [[SIMD3<Float>]],
                              skeleton: MeshResource.Skeleton?,
                              jointInfluences: MeshResource.JointInfluences?) throws -> MeshResource {
        var part = MeshResource.Part(id: UUID().uuidString, materialIndex: 0)
        part.positions = MeshBuffer(positions)
        if !normals.isEmpty {
            part.normals = MeshBuffer(normals)
        }
        if !tangentFrame.tangents.isEmpty {
            part.tangents = MeshBuffer(tangentFrame.tangents)
            part.bitangents = MeshBuffer(tangentFrame.bitangents)
        }
        if !texcoords.isEmpty {
            part.textureCoordinates = MeshBuffer(texcoords)
        }
        part.triangleIndices = MeshBuffer(indices)
        if !blendShapeOffsets.isEmpty {
            for (targetIndex, offsets) in blendShapeOffsets.enumerated() {
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

    /// A complete tangent basis. RealityKit derives neither buffer from the other,
    /// so both are filled together or left empty together.
    private struct TangentFrame {
        static let empty = TangentFrame(tangents: [], bitangents: [])

        let tangents: [SIMD3<Float>]
        let bitangents: [SIMD3<Float>]
    }

    /// The tangent basis a normal map needs: glTF `TANGENT` when the primitive has
    /// one, otherwise derived from the UVs. Skipped when no normal map samples it.
    private func tangentFrame(rawTangents: [SIMD4<Float>]?,
                              positions: [SIMD3<Float>],
                              normals: [SIMD3<Float>],
                              texcoords: [SIMD2<Float>],
                              indices: [UInt32],
                              materialIndex: Int?) -> TangentFrame {
        if let rawTangents {
            // glTF stores handedness in w.
            var tangents = [SIMD3<Float>](repeating: .zero, count: positions.count)
            var bitangents = tangents
            for i in 0..<positions.count {
                let raw = rawTangents[i]
                let tangent = SIMD3<Float>(raw.x, raw.y, raw.z)
                tangents[i] = tangent
                bitangents[i] = simd_cross(normals[i], tangent) * (raw.w < 0 ? -1 : 1)
            }
            return TangentFrame(tangents: tangents, bitangents: bitangents)
        }
        guard texcoords.count == positions.count,
              let materialIndex,
              materialUsesNormalTexture(withMaterialIndex: materialIndex) else {
            return .empty
        }
        return generatedTangentFrame(positions: positions,
                                     normals: normals,
                                     texcoords: texcoords,
                                     indices: indices)
    }

    /// Whether the material samples a normal map. The MToon descriptor is asked
    /// first because VRM 0.x carries its normal map in Unity's `_BumpMap`.
    private func materialUsesNormalTexture(withMaterialIndex index: Int) -> Bool {
        if let descriptor = try? mtoonDescriptor(withMaterialIndex: index), descriptor.normalTexture != nil {
            return true
        }
        guard let (gltfMaterial, _) = try? materialSource(withMaterialIndex: index) else { return false }
        return gltfMaterial.normalTexture != nil
    }

    /// Per-triangle UV gradients accumulated per vertex, then orthonormalized
    /// against the normal. The spec only *recommends* MikkTSpace here, and this
    /// averaging is the cheaper approximation, so a mesh whose baked normal map
    /// assumes MikkTSpace can differ slightly along UV seams.
    private func generatedTangentFrame(positions: [SIMD3<Float>],
                                       normals: [SIMD3<Float>],
                                       texcoords: [SIMD2<Float>],
                                       indices: [UInt32]) -> TangentFrame {
        var tangentSums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var bitangentSums = tangentSums
        let triangleCount = indices.count / 3
        for i in 0..<triangleCount {
            let base = i * 3
            let i0 = Int(indices[base])
            let i1 = Int(indices[base + 1])
            let i2 = Int(indices[base + 2])

            let edge1 = positions[i1] - positions[i0]
            let edge2 = positions[i2] - positions[i0]
            // `texcoords` point v up while the normal map works in glTF UV space,
            // so the v gradients are negated back into it.
            let deltaUV1 = gltfUVDelta(texcoords[i1] - texcoords[i0])
            let deltaUV2 = gltfUVDelta(texcoords[i2] - texcoords[i0])

            // A degenerate UV triangle carries no direction.
            let determinant = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y
            guard abs(determinant) > 1e-12 else { continue }
            let scale = 1 / determinant
            let tangent = (edge1 * deltaUV2.y - edge2 * deltaUV1.y) * scale
            let bitangent = (edge2 * deltaUV1.x - edge1 * deltaUV2.x) * scale
            tangentSums[i0] += tangent
            tangentSums[i1] += tangent
            tangentSums[i2] += tangent
            bitangentSums[i0] += bitangent
            bitangentSums[i1] += bitangent
            bitangentSums[i2] += bitangent
        }

        var tangents = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var bitangents = tangents
        for i in 0..<positions.count {
            let normal = normals[i]
            let tangent = orthonormalizedTangent(tangentSums[i], normal: normal)
            tangents[i] = tangent
            // Mirrored UV islands need the flipped bitangent.
            let bitangent = simd_cross(normal, tangent)
            bitangents[i] = simd_dot(bitangent, bitangentSums[i]) < 0 ? -bitangent : bitangent
        }
        return TangentFrame(tangents: tangents, bitangents: bitangents)
    }

    /// A UV difference converted from the mesh's v-up coordinates into glTF UV space.
    private func gltfUVDelta(_ delta: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(delta.x, -delta.y)
    }

    /// Gram-Schmidt against the normal, falling back to any perpendicular axis.
    private func orthonormalizedTangent(_ tangent: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
        // A degenerate triangle leaves the zero normal `flatNormals()` writes, and
        // nothing is perpendicular to it, so normalizing a fallback axis would
        // only turn that into a NaN basis.
        guard simd_length_squared(normal) > 1e-12 else { return .zero }
        let projected = tangent - normal * simd_dot(normal, tangent)
        if simd_length_squared(projected) > 1e-12 {
            return simd_normalize(projected)
        }
        let axis = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return simd_normalize(simd_cross(normal, axis))
    }

    /// The flat normals glTF asks for when a primitive ships no NORMAL: one face
    /// normal shared by the triangle's three corners.
    ///
    /// - Precondition: the positions are expanded per triangle corner, so each
    ///   triangle owns the vertices it writes.
    private func flatNormals(positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for base in stride(from: 0, to: positions.count - positions.count % 3, by: 3) {
            let faceNormal = simd_cross(positions[base + 1] - positions[base],
                                        positions[base + 2] - positions[base])
            // A degenerate triangle keeps a zero normal rather than a NaN one.
            guard simd_length_squared(faceNormal) > 1e-24 else { continue }
            let normal = simd_normalize(faceNormal)
            normals[base] = normal
            normals[base + 1] = normal
            normals[base + 2] = normal
        }
        return normals
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
