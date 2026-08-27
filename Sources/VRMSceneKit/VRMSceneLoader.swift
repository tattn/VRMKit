import Foundation
import VRMKit
import VRMKitRuntime
import SceneKit
import SpriteKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
open class VRMSceneLoader {
    let vrm: VRM
    let document: GLTFDocument
    private var gltf: GLTF { document.gltf }
    private let sceneData: SceneData
    /// Accessors expanded once and shared, and where they are validated.
    private let accessors: PackedAccessorCache
    /// Node parents, built and validated once by ``validateStructure()``.
    private var nodeHierarchy: GLTFNodeHierarchy?
    /// Which meshes a first-person camera cuts, read as the meshes are built.
    private var firstPersonPlan: VRMFirstPersonPlan?

    public init(vrm: VRM) {
        self.vrm = vrm
        self.document = vrm.document
        self.sceneData = SceneData(vrm: vrm.document.gltf)
        self.accessors = PackedAccessorCache(document: vrm.document)
    }

    public func loadScene() throws -> VRMScene {
        try loadScene(withSceneIndex: gltf.defaultSceneIndex())
    }

    /// Builds the scene at `index`. Every call returns a graph of its own, since
    /// a node has one parent and expressions pose the materials.
    public func loadScene(withSceneIndex index: Int) throws -> VRMScene {
        let hierarchy = try validateStructure()
        let gltfScene = try gltf.load(\.scenes, at: index)
        sceneData.beginScene()

        let vrmNode = VRMNode(vrm: vrm)
        try hierarchy.validateSceneRoots(gltfScene.nodes ?? [], sceneIndex: index)
        for node in gltfScene.nodes ?? [] {
            vrmNode.addChildNode(try self.node(withNodeIndex: node))
        }
        vrmNode.setUpHumanoid(nodes: sceneData.nodes)
        try vrmNode.setUpBlendShapes(nodes: sceneData.nodes, meshes: sceneData.meshes, loader: self)
        vrmNode.setUpFirstPerson(plan: firstPerson(),
                                 nodes: sceneData.nodes,
                                 meshes: sceneData.meshes,
                                 primitives: sceneData.firstPersonPrimitives)
        try vrmNode.setUpNodeConstraints(gltfNodes: try gltf.load(\.nodes),
                                         hierarchy: hierarchy,
                                         loader: self)
        try vrmNode.setUpSpringBones(loader: self)

        return VRMScene(node: vrmNode)
    }

    public func loadThumbnail() throws -> VRMImage {
        let imageIndex = try vrm.thumbnailImageIndex
        if let cache = try sceneData.load(\.images, index: imageIndex) { return cache }
        return try image(withImageIndex: imageIndex)
    }

    /// Validates the node graph and skins, once per document. Building a node
    /// reparents whatever it is handed, so a cyclic or multiply-parented hierarchy
    /// has to be rejected before the first node is built.
    private func validateStructure() throws -> GLTFNodeHierarchy {
        if let nodeHierarchy { return nodeHierarchy }
        let hierarchy = try GLTFNodeHierarchy.validatingStructure(of: gltf)
        nodeHierarchy = hierarchy
        return hierarchy
    }

    func firstPerson() -> VRMFirstPersonPlan {
        if let firstPersonPlan { return firstPersonPlan }
        let plan = VRMFirstPersonPlan(vrm: vrm, gltf: gltf, hierarchy: nodeHierarchy ?? .none)
        firstPersonPlan = plan
        return plan
    }

    /// The vertices of `primitive` the head is skinned into, or nil for a
    /// primitive no first-person camera cuts.
    func firstPersonHeadVertices(of primitive: GLTF.Mesh.Primitive,
                                 ofNodeAt nodeIndex: Int,
                                 meshIndex: Int,
                                 skinIndex: Int?) throws -> Set<Int>? {
        let headJoints = firstPerson().headJoints(ofNodeAt: nodeIndex,
                                                  meshIndex: meshIndex,
                                                  skinIndex: skinIndex)
        guard !headJoints.isEmpty,
              let jointsAccessor = primitive.attributes[.JOINTS_0],
              let weightsAccessor = primitive.attributes[.WEIGHTS_0] else { return nil }
        let joints = try accessors.accessor(at: jointsAccessor).jointIndices()
        let weights = try accessors.accessor(at: weightsAccessor).jointWeights()
        return FirstPersonAutoMask.headVertices(joints: joints, weights: weights, headJoints: headJoints)
    }

    func node(withNodeIndex index: Int) throws -> SCNNode {
        if let cache = try sceneData.load(\.nodes, index: index) { return cache }
        let gltfNode = try gltf.load(\.nodes, at: index)
        let scnNode = try SCNNode(node: gltfNode, at: index, loader: self)
        sceneData.nodes[index] = scnNode
        return scnNode
    }

    func camera(withCameraIndex index: Int) throws -> SCNCamera {
        if let cache = try sceneData.load(\.cameras, index: index) { return cache }
        let gltfCamera = try gltf.load(\.cameras, at: index)
        let camera = try SCNCamera(camera: gltfCamera)
        sceneData.cameras[index] = camera
        return camera
    }

    /// A node for the mesh at `index`. Every reference gets its own, an `SCNNode`
    /// belonging to one parent, while the geometry sources, materials and textures
    /// underneath stay shared.
    func mesh(withMeshIndex index: Int, skinIndex: Int?, nodeIndex: Int) throws -> SCNNode {
        let gltfMesh = try gltf.load(\.meshes, at: index)
        let mesh = try SCNNode(mesh: gltfMesh,
                               at: index,
                               skinIndex: skinIndex,
                               nodeIndex: nodeIndex,
                               loader: self)
        sceneData.meshes[index, default: []].append(.init(nodeIndex: nodeIndex, node: mesh))
        return mesh
    }

    /// The sources arrive in ``GLTF/Mesh/Primitive/AttributeKey`` order rather than
    /// the dictionary's: SceneKit resolves a material's `mappingChannel` by which
    /// `.texcoord` source comes first.
    func attributes(_ attributes: [GLTF.Mesh.Primitive.AttributeKey: Int]) throws -> [SCNGeometrySource] {
        return try attributes.sortedByKey.compactMap { attribute, index in
            guard let semantic = semantic(of: attribute) else { return nil }
            let key = SceneData.GeometrySourceKey(accessor: index, semantic: semantic)
            if let cache = sceneData.geometrySources[key] { return cache }
            let source = SCNGeometrySource(accessor: try accessors.accessor(at: index), semantic: key.semantic)
            sceneData.geometrySources[key] = source
            return source
        }
    }

    /// Not cached: an element carries the primitive mode as well as the
    /// accessor, and building one off an accessor already expanded is cheap.
    func indexAccessor(withAccessorIndex index: Int, mode: GLTF.Mesh.Primitive.Mode) throws -> SCNGeometryElement {
        try SCNGeometryElement(accessor: try accessors.accessor(at: index), mode: mode)
    }

    func inverseBindMatrix(withAccessorIndex index: Int) throws -> [InverseBindMatrix] {
        try [InverseBindMatrix](accessor: try accessors.accessor(at: index))
    }

    func recordFirstPersonPrimitive(_ primitive: FirstPersonPrimitive) {
        sceneData.firstPersonPrimitives[ObjectIdentifier(primitive.thirdPerson)] = primitive
    }

    func skin(withSkinIndex index: Int) throws -> GLTF.Skin {
        try gltf.load(\.skins, at: index)
    }

    /// An `SCNSkinner` binds one geometry, so every primitive gets its own even
    /// where they share a glTF skin.
    func skin(primitiveGeometry: SCNGeometry,
              bones: [SCNNode],
              boneInverseBindTransform ibm: [InverseBindMatrix]?) throws -> SCNSkinner {
        try SCNSkinner(primitiveGeometry: primitiveGeometry, bones: bones, boneInverseBindTransform: ibm)
    }

    func material(withMaterialIndex index: Int) throws -> SCNMaterial {
        if let cache = try sceneData.load(\.materials, index: index) { return cache }
        let gltfMaterial = try gltf.load(\.materials, at: index)
        let material = try SCNMaterial(material: gltfMaterial, at: index, loader: self)
        sceneData.materials[index] = material
        return material
    }

    func vrm0MaterialProperty(at index: Int) -> VRM0.MaterialProperty? {
        vrm.vrm0MaterialProperty(at: index)
    }

    /// The Unity render queue the material at `index` is drawn in, which is
    /// what a `renderingOrder` is derived from.
    func renderQueue(forMaterialAt index: Int?) throws -> Int? {
        guard let index else { return nil }
        // A `VRM_USE_GLTFSHADER` material is the glTF material as it is, so its
        // queue follows from the alpha mode as any other document's would.
        if let property = vrm0MaterialProperty(at: index), property.vrmShader != .gltfShader {
            return property.renderQueue
        }
        guard let material = try gltf.load(\.materials)[safe: index] else { return nil }
        let mtoon = material.extensions?.materialsMToon
        return material.alphaMode.vrm0RenderQueue(transparentWithZWrite: mtoon?.transparentWithZWrite == true)
            + (mtoon?.renderQueueOffsetNumber ?? 0)
    }

    func texture(withTextureIndex index: Int) throws -> SCNMaterialProperty {
        if let cache = try sceneData.load(\.textures, index: index) { return cache }
        let gltfTexture = try gltf.load(\.textures, at: index)
        let texture = SCNMaterialProperty(contents: try image(withImageIndex: gltfTexture.source))
        if let sampler = gltfTexture.sampler {
            texture.setSampler(try gltf.load(\.samplers, at: sampler))
        } else {
            texture.wrapS = .repeat
            texture.wrapT = .repeat
        }
        sceneData.textures[index] = texture
        return texture
    }

    /// SceneKit reads a texture's contents as a platform image, so what the
    /// document decodes is wrapped once here and cached wrapped.
    func image(withImageIndex index: Int) throws -> VRMImage {
        if let cache = try sceneData.load(\.images, index: index) { return cache }
        let image = VRMImage(cgImage: try document.image(at: index))
        sceneData.images[index] = image
        return image
    }
}
