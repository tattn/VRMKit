//
//  VRM1SceneLoader.swift
//  VRMKit
//
//  Created by GH on 6/13/25.
//

import Foundation
import VRMKit
import SceneKit
import UIKit

open class VRM1SceneLoader {
    let vrm1: VRM1
    private let gltf: GLTF
    private let sceneData: SceneData
    private var rootDirectory: URL? = nil
    
    public init(vrm1: VRM1, rootDirectory: URL? = nil) {
        self.vrm1 = vrm1
        self.gltf = vrm1.gltf.jsonData
        self.rootDirectory = rootDirectory
        self.sceneData = SceneData(vrm: gltf)
    }
    
    public func loadThumbnail() throws -> UIImage? {
        guard let imageIndex = vrm1.meta.thumbnailImage else {
            return nil
        }
        
        if let cache = try sceneData.load(\.images, index: imageIndex) {
            return cache
        }
        
        return try image(withImageIndex: imageIndex)
    }
    
    func image(withImageIndex index: Int) throws -> UIImage {
        if let cache = try sceneData.load(\.images, index: index) {
            return cache
        }
        
        guard let gltfImages = gltf.images else {
            throw VRMError.keyNotFound("images")
        }
        
        guard index >= 0 && index < gltfImages.count,
              let gltfImage = gltfImages[safe: index] else {
            throw VRMError.dataInconsistent("Image index \(index) is out of bounds for \(gltfImages.count) images.")
        }
        
        let image = try UIImage(image: gltfImage, relativeTo: rootDirectory, loader: self)
        sceneData.images[index] = image
        return image
    }

    func bufferView(withBufferViewIndex index: Int) throws -> (bufferView: Data, stride: Int?) {
        guard let gltfBufferViews = gltf.bufferViews else {
            throw VRMError.keyNotFound("bufferViews")
        }
        
        guard index >= 0 && index < gltfBufferViews.count,
              let gltfBufferView = gltfBufferViews[safe: index] else {
            throw VRMError.dataInconsistent("BufferView index \(index) is out of bounds for \(gltfBufferViews.count) bufferViews.")
        }
        
        if let cache = try sceneData.load(\.bufferViews, index: index) {
            return (cache, gltfBufferView.byteStride)
        }
        
        let buffer = try self.buffer(withBufferIndex: gltfBufferView.buffer)
        let bufferData = buffer.subdata(in: gltfBufferView.byteOffset..<(gltfBufferView.byteOffset + gltfBufferView.byteLength))
        
        sceneData.bufferViews[index] = bufferData
        return (bufferData, gltfBufferView.byteStride)
    }
    
    private func buffer(withBufferIndex index: Int) throws -> Data {
        if let cache = try sceneData.load(\.buffers, index: index) {
            return cache
        }
        
        guard let gltfBuffers = gltf.buffers else {
            throw VRMError.keyNotFound("buffers")
        }
        
        guard index >= 0 && index < gltfBuffers.count,
              let gltfBuffer = gltfBuffers[safe: index] else {
            throw VRMError.dataInconsistent("Buffer index \(index) is out of bounds for \(gltfBuffers.count) buffers.")
        }
        
        let data: Data
        if let uri = gltfBuffer.uri {
            data = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let binaryBuffer = vrm1.gltf.binaryBuffer {
            data = binaryBuffer
        } else {
            throw VRMError._dataInconsistent("failed to load buffers")
        }
        
        sceneData.buffers[index] = data
        return data
    }
}

extension VRM1SceneLoader {
    public convenience init(withURL url: URL, rootDirectory: URL? = nil) throws {
        let vrm1 = try VRMLoader().load(VRM1.self, withURL: url)
        self.init(vrm1: vrm1, rootDirectory: rootDirectory)
    }
    
    public convenience init(named: String, rootDirectory: URL? = nil) throws {
        let vrm1 = try VRMLoader().load(VRM1.self, named: named)
        self.init(vrm1: vrm1, rootDirectory: rootDirectory)
    }
    
    public convenience init(withData data: Data, rootDirectory: URL? = nil) throws {
        let vrm1 = try VRMLoader().load(VRM1.self, withData: data)
        self.init(vrm1: vrm1, rootDirectory: rootDirectory)
    }
}
