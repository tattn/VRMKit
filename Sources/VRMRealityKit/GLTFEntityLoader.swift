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
    static let logger = Logger(subsystem: "dev.tattn.VRMKit", category: "MToon")
    static let gltfLogger = Logger(subsystem: "dev.tattn.VRMKit", category: "glTF")

    private var didValidateStructure = false
    /// glTF node index → its parent, built and validated once by
    /// ``validateStructure()`` and read by everything that walks upwards.
    private var nodeParents: [Int: Int] = [:]
    private var loggedLimitations: Set<String> = []
    private var materialTexCoordCache: [Int: (selected: Int, isMixed: Bool)] = [:]
    private var morphTargetCounts: [Int: Int] = [:]

    private func logOnce(_ key: String, _ message: @autoclosure () -> String) {
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
    private var fallbackTextureCache: [MToonTextureSlot.Fallback: TextureResource] = [:]
    private var mtoonDescriptorCache: [Int: MToonMaterialDescriptor?] = [:]
#if !os(visionOS)
    /// Everything derived from one MToon material. A non-nil state is what
    /// "this material renders as MToon" means.
    private struct MToonState {
        let descriptor: MToonMaterialDescriptor
        let parameters: MToonMaterialParameters
        let parameterTexture: CustomMaterial.Texture
        let library: MTLLibrary
    }

    private var mtoonStateCache: [Int: MToonState?] = [:]
    private var mtoonOutlineMaterialCache: [Int: Material?] = [:]
#endif
    private var loggedMToonLibraryError = false
    /// When `false`, MToon materials are not created and the loader falls back to Unlit / PBR materials.
    /// visionOS always uses the fallback because `CustomMaterial` is unavailable there.
    public let isMToonEnabled: Bool
    /// Controls creation of MToon's inverted-hull outline entities.
    /// visionOS does not create MToon outlines because `CustomMaterial` is unavailable there.
    public let isOutlineEnabled: Bool
    public init(document: GLTFDocument,
                isMToonEnabled: Bool = true,
                isOutlineEnabled: Bool = true) {
        self.document = document
        self.entityData = EntityData(gltf: document.gltf)
        self.accessors = PackedAccessorCache(document: document)
        self.isMToonEnabled = isMToonEnabled
        self.isOutlineEnabled = isOutlineEnabled
    }

    /// Loads a `.glb` / `.gltf` file. External resources resolve relative to
    /// the file's directory.
    public convenience init(withURL url: URL,
                            isMToonEnabled: Bool = true,
                            isOutlineEnabled: Bool = true) throws {
        self.init(document: try GLTFLoader().load(withURL: url),
                  isMToonEnabled: isMToonEnabled,
                  isOutlineEnabled: isOutlineEnabled)
    }

    /// Loads a bundled glTF resource.
    public convenience init(named: String,
                            isMToonEnabled: Bool = true,
                            isOutlineEnabled: Bool = true) throws {
        self.init(document: try GLTFLoader().load(named: named),
                  isMToonEnabled: isMToonEnabled,
                  isOutlineEnabled: isOutlineEnabled)
    }

    /// Loads in-memory glTF data. `rootDirectory` is the base directory for
    /// external resources.
    public convenience init(withData data: Data,
                            rootDirectory: URL? = nil,
                            isMToonEnabled: Bool = true,
                            isOutlineEnabled: Bool = true) throws {
        self.init(document: try GLTFLoader().load(withData: data, rootDirectory: rootDirectory),
                  isMToonEnabled: isMToonEnabled,
                  isOutlineEnabled: isOutlineEnabled)
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
    /// new graph — even for the same scene — while resources are reused.
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
        for node in gltfScene.nodes ?? [] {
            // Attaching a node that already has a parent would reparent it away
            // from that parent, making the graph depend on `scene.nodes` order.
            if let parent = nodeParents[node] {
                throw VRMError._dataInconsistent(
                    "scene \(index) names node \(node) as a root, but it is a child of node \(parent)"
                )
            }
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

    /// glTF extensions this renderer implements, to satisfy `extensionsRequired`.
    ///
    /// Not an override point outside this module: claiming an extension this
    /// renderer cannot draw would only silence the check that rejects it.
    public var supportedRequiredExtensions: Set<String> {
        var extensions: Set<String> = ["KHR_materials_unlit", "KHR_texture_transform"]
        // MToon renders through CustomMaterial and a precompiled Metal library, so
        // a platform without either — visionOS, Mac Catalyst — cannot claim it, and
        // neither can a loader with MToon turned off.
#if !os(visionOS)
        if isMToonEnabled, MToonShaderLibraryLoader.resourceName != nil {
            extensions.insert("VRMC_materials_mtoon")
        }
#endif
        return extensions
    }

    /// Fails the load when the file requires an extension this renderer does not
    /// implement, as the glTF spec demands, or leans on a required extension past
    /// what this renderer implements of it.
    func validateRequiredExtensions() throws {
        if let unsupported = unsupportedRequiredExtensions().first {
            throw VRMError._notSupported("this glTF requires the \(unsupported) extension")
        }
        if gltf.extensionsRequired?.contains("KHR_texture_transform") == true {
            try validateTextureTransformsAreRenderable()
        }
    }

    /// RealityKit gives a material one UV transform, so `KHR_texture_transform` is
    /// only fully implemented while a material's textures agree on theirs.
    ///
    /// An asset that merely *uses* the extension renders through the first
    /// transform and logs the approximation; one that *requires* it is asking for
    /// a result this renderer cannot draw, so it is rejected instead.
    private func validateTextureTransformsAreRenderable() throws {
        for (index, gltfMaterial) in (gltf.materials ?? []).enumerated() {
            let transforms = sampledTextures(of: gltfMaterial).map { $0.transform ?? GLTFUVTransform() }
            guard transforms.allSatisfy({ $0 == transforms.first }) else {
                throw VRMError._notSupported(
                    "this glTF requires KHR_texture_transform, and material \(index) gives its textures different transforms, which this renderer cannot draw"
                )
            }
        }
    }

    /// `extensionsRequired` entries outside ``supportedRequiredExtensions``.
    func unsupportedRequiredExtensions() -> [String] {
        (gltf.extensionsRequired ?? []).filter { !supportedRequiredExtensions.contains($0) }
    }

    /// Rejects, once per document, the malformed node graphs and skins the rest
    /// of the loader takes for granted: the spec guarantees the nodes form a
    /// forest and that a skin names at least one joint, each of them once.
    ///
    /// Without this, a cyclic hierarchy would recurse forever and a repeated or
    /// out-of-range joint would trap instead of throwing.
    private func validateStructure() throws {
        guard !didValidateStructure else { return }
        let nodes = gltf.nodes ?? []

        var parents: [Int: Int] = [:]
        for (index, node) in nodes.enumerated() {
            for child in node.children ?? [] {
                guard nodes.indices.contains(child) else {
                    throw VRMError._dataInconsistent("node \(index) has a child \(child) of \(nodes.count) nodes")
                }
                guard parents.updateValue(index, forKey: child) == nil else {
                    throw VRMError._dataInconsistent("node \(child) is a child of more than one node")
                }
            }
        }
        nodeParents = parents
        // With at most one parent each, the hierarchy is a forest unless walking
        // up from a node returns to a node already on the way up.
        var verified: Set<Int> = []
        for index in nodes.indices where !verified.contains(index) {
            var chain: Set<Int> = []
            var current = index
            while !verified.contains(current) {
                guard chain.insert(current).inserted else {
                    throw VRMError._dataInconsistent("the node hierarchy is cyclic at node \(current)")
                }
                guard let parent = parents[current] else { break }
                current = parent
            }
            verified.formUnion(chain)
        }

        for (index, skin) in (gltf.skins ?? []).enumerated() {
            guard !skin.joints.isEmpty else {
                throw VRMError._dataInconsistent("skin \(index) names no joint")
            }
            var seen: Set<Int> = []
            for joint in skin.joints {
                guard nodes.indices.contains(joint) else {
                    throw VRMError._dataInconsistent("skin \(index) has a joint \(joint) of \(nodes.count) nodes")
                }
                guard seen.insert(joint).inserted else {
                    throw VRMError._dataInconsistent("skin \(index) names node \(joint) as a joint twice")
                }
            }
        }

        didValidateStructure = true
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
        entity.transform = transform(from: gltfNode)

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

    /// Applies the spec's starting morph state — `node.weights`, falling back to
    /// `mesh.weights` — so the first frame renders correctly without animation.
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
            if let primitiveEntity = try modelEntity(withPrimitive: primitive, skinIndex: skinIndex) {
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

    private func modelEntity(withPrimitive primitive: GLTF.Mesh.Primitive, skinIndex: Int?) throws -> Entity? {
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

        let material = try primitive.material.map { try primitiveMaterial(withMaterialIndex: $0) }
            ?? defaultMaterial()

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

        let modelEntity = makeEntity(materials: [material])
        if let materialIndex = primitive.material,
           let outlineMaterial = try mtoonOutlineMaterial(withMaterialIndex: materialIndex) {
            let outlineEntity = makeEntity(materials: [outlineMaterial])
            outlineEntity.name = "\(modelEntity.name)_outline"
            let container = Entity()
            container.name = "\(modelEntity.name)_container"
            container.addChild(outlineEntity)
            container.addChild(modelEntity)
            return container
        }
        return modelEntity
    }

    /// The UV set this primitive's mesh feeds RealityKit. Custom meshes carry a
    /// single UV channel, so the material's first UV-accessed texture decides it.
    private func texcoordAttributeKey(forMaterialIndex materialIndex: Int?,
                                      attributes: [GLTF.Mesh.Primitive.AttributeKey: Int]) -> GLTF.Mesh.Primitive.AttributeKey {
        guard let materialIndex else { return .TEXCOORD_0 }
        let resolved: (selected: Int, isMixed: Bool)
        if let cached = materialTexCoordCache[materialIndex] {
            resolved = cached
        } else {
            guard let gltfMaterial = try? gltf.load(\.materials, at: materialIndex) else {
                return .TEXCOORD_0
            }
            let textures = sampledTextures(of: gltfMaterial)
            resolved = (textures.first?.texCoord ?? 0, textures.contains { $0.texCoord != textures.first?.texCoord })
            materialTexCoordCache[materialIndex] = resolved
        }
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

    /// The material a primitive renders with. ``VRMEntityLoader`` overrides it to
    /// keep rendering a model whose material this renderer cannot build.
    func primitiveMaterial(withMaterialIndex index: Int) throws -> Material {
        try material(withMaterialIndex: index)
    }

    func material(withMaterialIndex index: Int) throws -> Material {
        if let cache = try entityData.load(\.materials, index: index) { return cache }
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
#if !os(visionOS)
        do {
            if let state = try mtoonState(withMaterialIndex: index) {
                let material = try customMToonMaterial(state)
                entityData.materials[index] = material
                return material
            }
        } catch {
            // The fallback material is not MToon, so the state has to go with it.
            discardMToonState(withMaterialIndex: index)
            Self.logger.error("Failed to build the MToon material \(index, privacy: .public); falling back to Unlit / PBR: \(String(describing: error), privacy: .public)")
        }
#endif

        let shaderName = materialProperty?.shader.lowercased()
        let isMToon = try mtoonDescriptor(withMaterialIndex: index) != nil
        let isUnlit = shaderName?.contains("unlit") == true || gltfMaterial.extensions?.materialsUnlit != nil
        // MToon and Unlit variants are not PBR, so both render through UnlitMaterial.
        let useUnlit = isMToon || isUnlit
        let resolvedAlphaMode = GLTF.Material.AlphaMode(vrm0: materialProperty,
                                                        fallback: gltfMaterial.alphaMode)
        let tint = gltfMaterial.pbrMetallicRoughness
            .map { VRMColor(simd: SIMD4<Float>($0.baseColorFactor)) } ?? .white

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
            entityData.materials[index] = material
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
        let emissiveTint = VRMColor(red: CGFloat(emissiveFactor.r),
                                   green: CGFloat(emissiveFactor.g),
                                   blue: CGFloat(emissiveFactor.b),
                                   alpha: 1)
        let hasEmissiveTint = emissiveFactor.r != 0 || emissiveFactor.g != 0 || emissiveFactor.b != 0
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

        entityData.materials[index] = material
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
    private func selectedUVTransform(withMaterialIndex index: Int,
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
    /// Only the rotation direction mirrors — offset and scale already act from
    /// the corner the extension measures from — which is what
    /// `TextureTransformRenderingTests` checks against what RealityKit draws.
    private func standardTextureTransform(withMaterialIndex index: Int,
                                          of gltfMaterial: GLTF.Material) -> MaterialParameterTypes.TextureCoordinateTransform {
        let transform = selectedUVTransform(withMaterialIndex: index,
                                            textures: sampledTextures(of: gltfMaterial))
        return MaterialParameterTypes.TextureCoordinateTransform(offset: transform.offset,
                                                                 scale: transform.scale,
                                                                 rotation: -transform.rotation)
    }

#if !os(visionOS)
    private func customMToonMaterial(_ state: MToonState) throws -> Material {
        let mtoon = state.descriptor
        let surface = CustomMaterial.SurfaceShader(named: "mtoonSurface", in: state.library)
        var material = try CustomMaterial(surfaceShader: surface, lightingModel: .unlit)
        // MToon needs more textures than CustomMaterial has semantic channels, so the
        // extra slots ride on unrelated ones; MToon.metal reads them back the same way.
        material.baseColor = .init(tint: .white, texture: try mtoonTexture(mtoon, slot: .base))
        material.roughness.texture = try mtoonTexture(mtoon, slot: .shade)
        material.specular.texture = try mtoonTexture(mtoon, slot: .shadingShift)
        material.metallic.texture = try mtoonTexture(mtoon, slot: .matcap)
        material.normal.texture = try mtoonTexture(mtoon, slot: .normal)
        material.emissiveColor = .init(color: .white, texture: try mtoonTexture(mtoon, slot: .emissive))
        material.clearcoatRoughness.texture = try mtoonTexture(mtoon, slot: .rim)
        material.clearcoat.texture = try mtoonTexture(mtoon, slot: .outlineWidth)
        material.ambientOcclusion.texture = try mtoonTexture(mtoon, slot: .uvAnimationMask)

        applyAlphaMode(mtoon.alphaMode, alphaCutoff: mtoon.alphaCutoff, to: &material)
        applyDepthWrite(mtoon, to: &material)
        material.faceCulling = mtoon.cullMode.faceCulling
        applyMToonParameters(state, to: &material)
        return material
    }

    private func customMToonOutlineMaterial(_ state: MToonState) throws -> Material {
        let mtoon = state.descriptor
        let surface = CustomMaterial.SurfaceShader(named: "mtoonOutlineSurface", in: state.library)
        let geometry = CustomMaterial.GeometryModifier(named: "mtoonOutlineGeometry", in: state.library)
        var material = try CustomMaterial(surfaceShader: surface,
                                          geometryModifier: geometry,
                                          lightingModel: .unlit)
        material.faceCulling = .front
        material.baseColor = .init(tint: .white, texture: try mtoonTexture(mtoon, slot: .base))
        material.clearcoat.texture = try mtoonTexture(mtoon, slot: .outlineWidth)
        material.ambientOcclusion.texture = try mtoonTexture(mtoon, slot: .uvAnimationMask)
        applyAlphaMode(mtoon.alphaMode, alphaCutoff: mtoon.alphaCutoff, to: &material)
        applyDepthWrite(mtoon, to: &material)
        applyMToonParameters(state, to: &material)
        return material
    }

    /// MToon.metal applies the UV transform from the parameter rows, so
    /// `textureCoordinateTransform` is deliberately left at identity here.
    private func applyMToonParameters(_ state: MToonState, to material: inout CustomMaterial) {
        material.custom.value = state.parameters.customValue
        material.custom.texture = state.parameterTexture
    }

    /// The descriptor's texture for `slot`, or the slot's neutral fallback.
    private func mtoonTexture(_ descriptor: MToonMaterialDescriptor,
                              slot: MToonTextureSlot) throws -> CustomMaterial.Texture {
        guard let texture = descriptor.texture(for: slot) else {
            return CustomMaterial.Texture(try fallbackTextureResource(slot.fallback))
        }
        return CustomMaterial.Texture(try self.texture(withTextureIndex: texture.index, semantic: slot.semantic))
    }
#endif

    func mtoonParameters(withMaterialIndex index: Int) throws -> MToonMaterialParameters? {
#if os(visionOS)
        return nil
#else
        return try mtoonState(withMaterialIndex: index)?.parameters
#endif
    }

#if !os(visionOS)
    private func mtoonState(withMaterialIndex index: Int) throws -> MToonState? {
        if let cached = mtoonStateCache[index] {
            return cached
        }
        let state = try makeMToonState(withMaterialIndex: index)
        mtoonStateCache[index] = state
        return state
    }

    /// Records that the material does not render as MToon after all.
    private func discardMToonState(withMaterialIndex index: Int) {
        mtoonStateCache.updateValue(nil, forKey: index)
        mtoonOutlineMaterialCache.updateValue(nil, forKey: index)
    }

    private func makeMToonState(withMaterialIndex index: Int) throws -> MToonState? {
        guard isMToonEnabled,
              let descriptor = try mtoonDescriptor(withMaterialIndex: index),
              let library = mtoonShaderLibrary() else {
            return nil
        }
        let textureTransform = mtoonTextureTransform(withMaterialIndex: index, descriptor: descriptor)
        let parameters = try mtoonParameters(for: descriptor, textureTransform: textureTransform)
        logMToonUnsupportedFeatures(for: descriptor, index: index)
        return MToonState(descriptor: descriptor,
                          parameters: parameters,
                          parameterTexture: CustomMaterial.Texture(try parameters.textureResource()),
                          library: library)
    }

    private func logMToonUnsupportedFeatures(for descriptor: MToonMaterialDescriptor, index: Int) {
        if descriptor.renderQueueOffsetNumber != 0 {
            Self.logger.warning("MToon material \(index, privacy: .public) requests renderQueueOffsetNumber \(descriptor.renderQueueOffsetNumber); RealityKit has no material-level draw-order hook, so it is ignored.")
        }
    }
#endif

    private func mtoonParameters(for descriptor: MToonMaterialDescriptor,
                                 textureTransform: MaterialParameterTypes.TextureCoordinateTransform) throws -> MToonMaterialParameters {
        var parameters = MToonMaterialParameters(descriptor)
        parameters.setTextureTransform(scale: textureTransform.scale,
                                       offset: textureTransform.offset,
                                       rotation: textureTransform.rotation)
        for slot in MToonTextureSlot.allCases {
            try parameters.setSampler(mtoonSamplerParameters(for: descriptor.texture(for: slot)), for: slot)
        }
        return parameters
    }

    /// MToon.metal transforms in glTF UV space, so unlike the standard path the
    /// transform passes through unconverted.
    private func mtoonTextureTransform(withMaterialIndex index: Int,
                                       descriptor: MToonMaterialDescriptor) -> MaterialParameterTypes.TextureCoordinateTransform {
        let textures = descriptor.uvAccessedTextures
        if textures.contains(where: { $0.texCoord != 0 }) {
            logOnce("mtoonTexCoord-\(index)",
                    "MToon material \(index) requests a nonzero texCoord; RealityKit uses TEXCOORD_0 on supported deployment targets.")
        }
        let selected = selectedUVTransform(withMaterialIndex: index, textures: textures)
        return MaterialParameterTypes.TextureCoordinateTransform(offset: selected.offset,
                                                                 scale: selected.scale,
                                                                 rotation: selected.rotation)
    }

    private func mtoonOutlineMaterial(withMaterialIndex index: Int) throws -> Material? {
#if os(visionOS)
        return nil
#else
        guard isOutlineEnabled else {
            return nil
        }
        if let cached = mtoonOutlineMaterialCache[index] {
            return cached
        }
        let material: Material?
        if let state = try mtoonState(withMaterialIndex: index), state.descriptor.hasOutline {
            material = try customMToonOutlineMaterial(state)
        } else {
            material = nil
        }
        mtoonOutlineMaterialCache[index] = material
        return material
#endif
    }

    private func mtoonDescriptor(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor? {
        if let cached = mtoonDescriptorCache[index] {
            return cached
        }
        let descriptor = try makeMToonDescriptor(withMaterialIndex: index)
        mtoonDescriptorCache[index] = descriptor
        return descriptor
    }

    private func makeMToonDescriptor(withMaterialIndex index: Int) throws -> MToonMaterialDescriptor? {
        let (gltfMaterial, materialProperty) = try materialSource(withMaterialIndex: index)
        return MToonMaterialDescriptor(material: gltfMaterial, materialProperty: materialProperty)
    }

    /// The glTF material and, for VRM 0.x, the Unity material property describing it.
    private func materialSource(withMaterialIndex index: Int) throws -> (GLTF.Material, VRM0.MaterialProperty?) {
        let gltfMaterial = try gltf.load(\.materials, at: index)
        return (gltfMaterial, vrm0MaterialProperty(for: gltfMaterial))
    }

    /// VRM 0.x compatibility hook, overridden by ``VRMEntityLoader``.
    func vrm0MaterialProperty(for gltfMaterial: GLTF.Material) -> VRM0.MaterialProperty? {
        nil
    }

    private func mtoonShaderLibrary() -> MTLLibrary? {
        do {
            return try MToonShaderLibraryLoader.loadDefault()
        } catch {
            if !loggedMToonLibraryError {
                loggedMToonLibraryError = true
                Self.logger.error("Failed to load bundled MToon shader library: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
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

    private func materialTexture(withTextureIndex index: Int,
                                 semantic: TextureResource.Semantic = .color) throws -> MaterialParameters.Texture {
        let texture = try texture(withTextureIndex: index, semantic: semantic)
        let sampler = try sampler(withTextureIndex: index)
        return MaterialParameters.Texture(texture, sampler: sampler)
    }

    /// The neutral 1x1 texture bound when a material omits an MToon slot.
    private func fallbackTextureResource(_ fallback: MToonTextureSlot.Fallback) throws -> TextureResource {
        if let cached = fallbackTextureCache[fallback] {
            return cached
        }
        let texture: TextureResource
        switch fallback {
        case .white:
            texture = try solidColorTextureResource(rgba: [255, 255, 255, 255], semantic: .color)
        case .neutralNormal:
            texture = try solidColorTextureResource(rgba: [128, 128, 255, 255], semantic: .normal)
        }
        fallbackTextureCache[fallback] = texture
        return texture
    }

    private func solidColorTextureResource(rgba: [UInt8],
                                           semantic: TextureResource.Semantic) throws -> TextureResource {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: 1,
                                  height: 1,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw VRMError._dataInconsistent("failed to create 1x1 \(semantic) texture")
        }
        return try TextureResource(image: image, options: .init(semantic: semantic))
    }

    private func sampler(withTextureIndex index: Int) throws -> MaterialParameters.Texture.Sampler {
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
    private func gltfSampler(withTextureIndex index: Int) throws -> GLTF.Sampler? {
        guard let samplerIndex = try gltf.load(\.textures, at: index).sampler else { return nil }
        return try gltf.load(\.samplers, at: samplerIndex)
    }

    private func applySampler(_ sampler: GLTF.Sampler?, to descriptor: MTLSamplerDescriptor) {
        descriptor.magFilter = metalFilter(sampler?.magFilter ?? .LINEAR)
        let (min, mip) = metalFilters(sampler?.minFilter ?? .LINEAR_MIPMAP_LINEAR)
        descriptor.minFilter = min
        descriptor.mipFilter = mip
        descriptor.sAddressMode = metalWrap(sampler?.wrapS ?? .REPEAT)
        descriptor.tAddressMode = metalWrap(sampler?.wrapT ?? .REPEAT)
    }

    private func mtoonSamplerParameters(for texture: MToonMaterialDescriptor.Texture?) throws -> SIMD4<Float> {
        guard let texture,
              let sampler = try gltfSampler(withTextureIndex: texture.index) else {
            return MToonMaterialParameters.defaultSampler
        }
        return mtoonSamplerParameters(sampler)
    }

    /// (wrapS, wrapT, filterIndex, 0), the sampler row layout `MToon.metal` expects.
    private func mtoonSamplerParameters(_ sampler: GLTF.Sampler) -> SIMD4<Float> {
        let (minFilter, mipFilter) = metalFilters(sampler.minFilter ?? .LINEAR_MIPMAP_LINEAR)
        let filter = MToonSamplerFilter(
            magnification: metalFilter(sampler.magFilter ?? .LINEAR) == .nearest ? .nearest : .linear,
            minification: minFilter == .nearest ? .nearest : .linear,
            mip: MToonSamplerFilter.MipFilter(mipFilter)
        )
        return SIMD4<Float>(mtoonWrapMode(sampler.wrapS),
                            mtoonWrapMode(sampler.wrapT),
                            Float(filter.index),
                            0)
    }

    private func mtoonWrapMode(_ wrap: GLTF.Sampler.Wrap) -> Float {
        switch wrap {
        case .REPEAT: return 0
        case .CLAMP_TO_EDGE: return 1
        case .MIRRORED_REPEAT: return 2
        }
    }

    private func metalFilter(_ filter: GLTF.Sampler.MagFilter) -> MTLSamplerMinMagFilter {
        switch filter {
        case .NEAREST: return .nearest
        case .LINEAR: return .linear
        }
    }

    private func metalFilters(_ filter: GLTF.Sampler.MinFilter) -> (min: MTLSamplerMinMagFilter, mip: MTLSamplerMipFilter) {
        switch filter {
        case .NEAREST:
            return (.nearest, .notMipmapped)
        case .LINEAR:
            return (.linear, .notMipmapped)
        case .NEAREST_MIPMAP_NEAREST:
            return (.nearest, .nearest)
        case .LINEAR_MIPMAP_NEAREST:
            return (.linear, .nearest)
        case .NEAREST_MIPMAP_LINEAR:
            return (.nearest, .linear)
        case .LINEAR_MIPMAP_LINEAR:
            return (.linear, .linear)
        }
    }

    private func metalWrap(_ wrap: GLTF.Sampler.Wrap) -> MTLSamplerAddressMode {
        switch wrap {
        case .CLAMP_TO_EDGE: return .clampToEdge
        case .MIRRORED_REPEAT: return .mirrorRepeat
        case .REPEAT: return .repeat
        }
    }

    func image(withImageIndex index: Int) throws -> VRMImage {
        if let cache = try entityData.load(\.images, index: index) { return cache }
        let gltfImage = try gltf.load(\.images, at: index)
        let image = try VRMImage.from(gltfImage, relativeTo: document.rootDirectory) { index in
            try document.bufferViewData(at: index).data
        }
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
    /// once per texture and factor.
    ///
    /// RealityKit's normal and ambient-occlusion parameters carry a texture and
    /// no scalar beside it, so a factor other than the neutral 1 has nowhere
    /// else to go.
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

    /// A copy of `image` with its pixels put through `rewrite`.
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

        let images = try withRGBA8Pixels(of: image) { _, pixels, pixelCount in
            let metalPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
            let roughPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
            defer {
                metalPtr.deallocate()
                roughPtr.deallocate()
            }
            for pixel in 0..<pixelCount {
                metalPtr[pixel] = pixels[pixel * 4 + 2]
                roughPtr[pixel] = pixels[pixel * 4 + 1]
            }
            return (metal: try createGraySpaceImage(width: image.width,
                                                    height: image.height,
                                                    dataPointer: metalPtr),
                    rough: try createGraySpaceImage(width: image.width,
                                                    height: image.height,
                                                    dataPointer: roughPtr))
        }

        // Metallic / roughness are linear data; .color would apply an sRGB conversion.
        return (try TextureResource(image: images.metal, options: .init(semantic: .raw)),
                try TextureResource(image: images.rough, options: .init(semantic: .raw)))
    }

    private func createGraySpaceImage(width: Int,
                                      height: Int,
                                      dataPointer: UnsafeMutablePointer<UInt8>) throws -> CGImage {
        guard let data = CFDataCreate(nil, dataPointer, width * height),
              let provider = CGDataProvider(data: data) else {
            throw VRMError._dataInconsistent("failed to create image data")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw VRMError._dataInconsistent("failed to create CGImage")
        }
        return image
    }

    /// The glTF alpha-mode → RealityKit blending decision, shared by every material.
    private struct AlphaModeSettings {
        let isTransparent: Bool
        let opacityThreshold: Float?

        init(_ mode: GLTF.Material.AlphaMode, alphaCutoff: Float) {
            switch mode {
            case .OPAQUE:
                (isTransparent, opacityThreshold) = (false, nil)
            case .MASK:
                (isTransparent, opacityThreshold) = (false, alphaCutoff)
            case .BLEND:
                (isTransparent, opacityThreshold) = (true, nil)
            }
        }
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout UnlitMaterial) {
        let settings = AlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout PhysicallyBasedMaterial) {
        let settings = AlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

#if !os(visionOS)
    private func applyAlphaMode(_ mode: GLTF.Material.AlphaMode,
                                alphaCutoff: Float,
                                to material: inout CustomMaterial) {
        let settings = AlphaModeSettings(mode, alphaCutoff: alphaCutoff)
        material.blending = settings.isTransparent ? .transparent(opacity: .init(scale: 1.0)) : .opaque
        material.opacityThreshold = settings.opacityThreshold
    }

    /// MToon's `transparentWithZWrite` asks a blended material to still write depth.
    private func applyDepthWrite(_ mtoon: MToonMaterialDescriptor, to material: inout CustomMaterial) {
        material.writesDepth = mtoon.alphaMode != .BLEND || mtoon.transparentWithZWrite
    }
#endif

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

    private func matrix4s(_ accessorIndex: Int) throws -> [simd_float4x4] {
        guard try accessors.accessor(at: accessorIndex).componentType == .float else {
            throw VRMError._dataInconsistent("MAT4 accessor must be float")
        }
        // glTF stores matrices column-major, which is also simd's layout.
        return try accessors.floatElements(at: accessorIndex, type: .MAT4) { component in
            simd_float4x4(columns: (
                SIMD4<Float>(component(0), component(1), component(2), component(3)),
                SIMD4<Float>(component(4), component(5), component(6), component(7)),
                SIMD4<Float>(component(8), component(9), component(10), component(11)),
                SIMD4<Float>(component(12), component(13), component(14), component(15))
            ))
        }
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
            inverseBindMatrices = try matrix4s(accessorIndex)
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

            let restTransform = transform(from: node)
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
            // `validateStructure()` has proven `nodeParents` to describe a forest,
            // so walking up from a joint terminates.
            var current = nodeIndex
            while let parent = nodeParents[current] {
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

    private func transform(from node: GLTF.Node) -> Transform {
        if let matrix = node._matrix {
            return Transform(matrix: matrix.simdMatrix)
        }
        return Transform(scale: node.scale.simd,
                         rotation: node.rotation.simdQuat,
                         translation: node.translation.simd)
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
    /// against the normal.
    ///
    /// The spec only *recommends* MikkTSpace for a primitive that ships no
    /// `TANGENT`; this averaging is the cheaper approximation, so a mesh whose
    /// baked normal map assumes MikkTSpace can differ slightly along UV seams.
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
        // nothing is perpendicular to it — normalizing a fallback axis would only
        // turn that into a NaN basis.
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
