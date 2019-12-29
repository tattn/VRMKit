//
//  VRMSceneLoader.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation
import VRMKit
import SceneKit
import SpriteKit

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
        let gltfScene = try gltf.load(\.scenes, keyName: "scenes")[index]
        
        let vrmNode = VRMNode(vrm: vrm)
        for node in gltfScene.nodes ?? [] {
            vrmNode.addChildNode(try self.node(withNodeIndex: node))
        }
        vrmNode.setUpHumanoid(nodes: sceneData.nodes)
        vrmNode.setUpBlendShapes(meshes: sceneData.meshes)
        try vrmNode.setUpSpringBones(loader: self)

        let scnScene = VRMScene(node: vrmNode)
        sceneData.scenes[index] = scnScene
        return scnScene
    }

    public func loadThumbnail() throws -> UIImage? {
        guard let textureIndex = vrm.meta.texture else { return nil }
        if let cache = try sceneData.load(\.images, index: textureIndex) { return cache }
        return try image(withImageIndex: textureIndex)
    }

    func node(withNodeIndex index: Int) throws -> SCNNode {
        if let cache = try sceneData.load(\.nodes, index: index) { return cache }
        let gltfNode = try gltf.load(\.nodes, keyName: "nodes")[index]
        let gltfSkins = try? gltf.load(\.skins, keyName: "skins")
        let scnNode = try SCNNode(node: gltfNode, skins: gltfSkins, loader: self)
        sceneData.nodes[index] = scnNode
        return scnNode
    }

    func camera(withCameraIndex index: Int) throws -> SCNCamera {
        if let cache = try sceneData.load(\.cameras, index: index) { return cache }
        let gltfCamera = try gltf.load(\.cameras, keyName: "cameras")[index]
        let camera = try SCNCamera(camera: gltfCamera)
        sceneData.cameras[index] = camera
        return camera
    }

    func mesh(withMeshIndex index: Int) throws -> SCNNode {
        if let cache = try sceneData.load(\.meshes, index: index) { return cache }
        let gltfMesh = try gltf.load(\.meshes, keyName: "meshes")[index]
        let mesh = try SCNNode(mesh: gltfMesh, loader: self)
        sceneData.meshes[index] = mesh
        return mesh
    }

    func attributes(_ attributes: [GLTF.Mesh.Primitive.AttributeKey: Int]) throws -> [SCNGeometrySource] {
        return try attributes.compactMap { attribute, index in
            guard attribute != .COLOR_0 else { return nil } // FIXME
            if let cache = try sceneData.load(\.accessors, index: index) as? SCNGeometrySource { return cache }
            let gltfAccessor = try gltf.load(\.accessors, keyName: "accessors")[index]
            let geometrySource = try SCNGeometrySource(accessor: gltfAccessor, semantic: semantic(of: attribute), loader: self)
            sceneData.accessors[index] = geometrySource
            return geometrySource
        }
    }

    func indexAccessor(withAccessorIndex index: Int, mode: GLTF.Mesh.Primitive.Mode) throws -> SCNGeometryElement {
        if let cache = try sceneData.load(\.accessors, index: index) as? SCNGeometryElement { return cache }
        let gltfAccessor = try gltf.load(\.accessors, keyName: "accessors")[index]
        let geometryElement = try SCNGeometryElement(accessor: gltfAccessor, mode: mode, loader: self)
        sceneData.accessors[index] = geometryElement
        return geometryElement
    }

    func inverseBindMatrix(withAccessorIndex index: Int) throws -> [InverseBindMatrix] {
        if let cache = try sceneData.load(\.accessors, index: index) as? [InverseBindMatrix] { return cache }
        let gltfAccessor = try gltf.load(\.accessors, keyName: "accessors")[index]
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
        let gltfBufferView = try gltf.load(\.bufferViews, keyName: "bufferViews")[index]
        if let cache = try sceneData.load(\.bufferViews, index: index) { return (cache, gltfBufferView.byteStride) }
        let buffer = try self.buffer(withBufferIndex: gltfBufferView.buffer)
        let bufferView = buffer.subdata(in: gltfBufferView.byteOffset..<gltfBufferView.byteOffset + gltfBufferView.byteLength)
        sceneData.bufferViews[index] = bufferView
        return (bufferView, gltfBufferView.byteStride)
    }

    private func buffer(withBufferIndex index: Int) throws -> Data {
        if let cache = try sceneData.load(\.buffers, index: index) { return cache }
        let gltfBuffer = try gltf.load(\.buffers, keyName: "buffers")[index]
        let buffer = try Data(buffer: gltfBuffer, relativeTo: rootDirectory, vrm: vrm)
        sceneData.buffers[index] = buffer
        return buffer
    }

    func material(withMaterialIndex index: Int) throws -> SCNMaterial {
        if let cache = try sceneData.load(\.materials, index: index) { return cache }
        let gltfMaterial = try gltf.load(\.materials, keyName: "materials")[index]
        let material = try SCNMaterial(material: gltfMaterial, loader: self)
        sceneData.materials[index] = material
        return material
    }

    func texture(withTextureIndex index: Int) throws -> SCNMaterialProperty {
        if let cache = try sceneData.load(\.textures, index: index) { return cache }
        let gltfTexture = try gltf.load(\.textures, keyName: "textures")[index]
        let texture = SCNMaterialProperty(contents: try image(withImageIndex: gltfTexture.source))
        if let sampler = gltfTexture.sampler {
            texture.setSampler(try gltf.load(\.samplers, keyName: "samplers")[sampler])
        } else {
            texture.wrapS = .repeat
            texture.wrapT = .repeat
        }
        sceneData.textures[index] = texture
        return texture
    }

    func image(withImageIndex index: Int) throws -> UIImage {
        if let cache = try sceneData.load(\.images, index: index) { return cache }
        let gltfImage = try gltf.load(\.images, keyName: "images")[index]
        let image = try UIImage(image: gltfImage, relativeTo: rootDirectory, loader: self)
        sceneData.images[index] = image
        return image
    }
}

private extension GLTF {
    func load<T>(_ keyPath: KeyPath<GLTF, T?>, keyName: String) throws -> T {
        return try self[keyPath: keyPath] ??? .keyNotFound(keyName)
    }
}
