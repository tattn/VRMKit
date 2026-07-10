import Foundation
import VRMKit
import VRMKitRuntime
import SceneKit
import SpriteKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
open class VRMSceneLoader {
    let vrm: VRM
    private let gltf: GLTF
    private let sceneData: SceneData

    private var rootDirectory: URL? = nil

    public init(vrm: VRM, rootDirectory: URL? = nil) {
        self.vrm = vrm
        self.gltf = vrm.gltf.jsonData
        self.rootDirectory = rootDirectory
        self.sceneData = SceneData(vrm: gltf)
    }

    public func loadScene() throws -> VRMScene {
        return try loadScene(withSceneIndex: gltf.scene)
    }

    public func loadScene(withSceneIndex index: Int) throws -> VRMScene {
        if let cache = try sceneData.load(\.scenes, index: index) { return cache }
        let gltfScene = try gltf.load(\.scenes)[index]
        
        let vrmNode = VRMNode(vrm: vrm)
        for node in gltfScene.nodes ?? [] {
            vrmNode.addChildNode(try self.node(withNodeIndex: node))
        }
        vrmNode.setUpHumanoid(nodes: sceneData.nodes)
        try vrmNode.setUpBlendShapes(nodes: sceneData.nodes, meshes: sceneData.meshes, loader: self)
        vrmNode.setUpFirstPerson(nodes: sceneData.nodes, meshes: sceneData.meshes)
        try vrmNode.setUpNodeConstraints(gltfNodes: try gltf.load(\.nodes), loader: self)
        try vrmNode.setUpSpringBones(loader: self)

        let scnScene = VRMScene(node: vrmNode)
        sceneData.scenes[index] = scnScene
        return scnScene
    }

    public func loadThumbnail() throws -> VRMImage {
        let imageIndex = try vrm.thumbnailImageIndex
        if let cache = try sceneData.load(\.images, index: imageIndex) { return cache }
        return try image(withImageIndex: imageIndex)
    }

    func node(withNodeIndex index: Int) throws -> SCNNode {
        if let cache = try sceneData.load(\.nodes, index: index) { return cache }
        let gltfNode = try gltf.load(\.nodes)[index]
        let gltfSkins = try? gltf.load(\.skins)
        let scnNode = try SCNNode(node: gltfNode, skins: gltfSkins, loader: self)
        sceneData.nodes[index] = scnNode
        return scnNode
    }

    func camera(withCameraIndex index: Int) throws -> SCNCamera {
        if let cache = try sceneData.load(\.cameras, index: index) { return cache }
        let gltfCamera = try gltf.load(\.cameras)[index]
        let camera = try SCNCamera(camera: gltfCamera)
        sceneData.cameras[index] = camera
        return camera
    }

    func mesh(withMeshIndex index: Int) throws -> SCNNode {
        if let cache = try sceneData.load(\.meshes, index: index) { return cache }
        let gltfMesh = try gltf.load(\.meshes)[index]
        let mesh = try SCNNode(mesh: gltfMesh, loader: self)
        sceneData.meshes[index] = mesh
        return mesh
    }

    func attributes(_ attributes: [GLTF.Mesh.Primitive.AttributeKey: Int]) throws -> [SCNGeometrySource] {
        return try attributes.compactMap { attribute, index in
            guard attribute != .COLOR_0 else { return nil } // FIXME
            if let cache = try sceneData.load(\.accessors, index: index) as? SCNGeometrySource { return cache }
            let gltfAccessor = try gltf.load(\.accessors)[index]
            let geometrySource = try SCNGeometrySource(accessor: gltfAccessor, semantic: semantic(of: attribute), loader: self)
            sceneData.accessors[index] = geometrySource
            return geometrySource
        }
    }

    func indexAccessor(withAccessorIndex index: Int, mode: GLTF.Mesh.Primitive.Mode) throws -> SCNGeometryElement {
        if let cache = try sceneData.load(\.accessors, index: index) as? SCNGeometryElement { return cache }
        let gltfAccessor = try gltf.load(\.accessors)[index]
        let geometryElement = try SCNGeometryElement(accessor: gltfAccessor, mode: mode, loader: self)
        sceneData.accessors[index] = geometryElement
        return geometryElement
    }

    func inverseBindMatrix(withAccessorIndex index: Int) throws -> [InverseBindMatrix] {
        if let cache = try sceneData.load(\.accessors, index: index) as? [InverseBindMatrix] { return cache }
        let gltfAccessor = try gltf.load(\.accessors)[index]
        let ibm = try [InverseBindMatrix](accessor: gltfAccessor, loader: self)
        sceneData.accessors[index] = ibm
        return ibm
    }

    func skin(withSkinIndex index: Int,
              primitiveGeometry: SCNGeometry,
              bones: [SCNNode],
              boneInverseBindTransform ibm: [InverseBindMatrix]?) throws -> SCNSkinner {
        //        if let cache = try sceneData.load(\.skins, index: index) { return cache } // FIXME:
        let skinner = try SCNSkinner(primitiveGeometry: primitiveGeometry, bones: bones, boneInverseBindTransform: ibm)
        sceneData.skins [index] = skinner
        return skinner
    }

    func bufferView(withBufferViewIndex index: Int) throws -> (bufferView: Data, stride: Int?) {
        if let cache = try sceneData.load(\.bufferViews, index: index) {
            let gltfBufferView = try gltf.load(\.bufferViews)[index]
            return (cache, gltfBufferView.byteStride)
        }
        let result = try vrm.gltf.bufferViewData(at: index, relativeTo: rootDirectory)
        sceneData.bufferViews[index] = result.data
        return (result.data, result.stride)
    }

    func material(withMaterialIndex index: Int) throws -> SCNMaterial {
        if let cache = try sceneData.load(\.materials, index: index) { return cache }
        let materials = try gltf.load(\.materials)
        guard materials.indices.contains(index) else {
            throw VRMError._dataInconsistent("Material index \(index) out of bounds")
        }
        let gltfMaterial = materials[index]
        let material = try SCNMaterial(material: gltfMaterial, loader: self)
        sceneData.materials[index] = material
        return material
    }

    func vrm0MaterialProperty(named name: String) -> VRM0.MaterialProperty? {
        guard case .v0(let vrm0) = vrm else { return nil }
        return vrm0.materialPropertyNameMap[name]
    }

    func renderQueue(forMaterialNamed name: String?) throws -> Int? {
        guard let name else { return nil }
        switch vrm {
        case .v0(let vrm0):
            return vrm0.materialPropertyNameMap[name]?.renderQueue
        case .v1:
            guard let material = try gltf.load(\.materials).first(where: { $0.name == name }) else {
                return nil
            }
            let baseQueue: Int
            switch material.alphaMode {
            case .OPAQUE:
                baseQueue = 2000
            case .MASK:
                baseQueue = 2450
            case .BLEND:
                baseQueue = material.extensions?.materialsMToon?.transparentWithZWrite == true ? 2501 : 3000
            }
            return baseQueue + (material.extensions?.materialsMToon?.renderQueueOffsetNumber ?? 0)
        }
    }

    func texture(withTextureIndex index: Int) throws -> SCNMaterialProperty {
        if let cache = try sceneData.load(\.textures, index: index) { return cache }
        let gltfTexture = try gltf.load(\.textures)[index]
        let texture = SCNMaterialProperty(contents: try image(withImageIndex: gltfTexture.source))
        if let sampler = gltfTexture.sampler {
            texture.setSampler(try gltf.load(\.samplers)[sampler])
        } else {
            texture.wrapS = .repeat
            texture.wrapT = .repeat
        }
        sceneData.textures[index] = texture
        return texture
    }

    func image(withImageIndex index: Int) throws -> VRMImage {
        if let cache = try sceneData.load(\.images, index: index) { return cache }
        let gltfImage = try gltf.load(\.images)[index]
        let image = try VRMImage.from(gltfImage, relativeTo: rootDirectory) { index in
            try self.bufferView(withBufferViewIndex: index).bufferView
        }
        sceneData.images[index] = image
        return image
    }
}
