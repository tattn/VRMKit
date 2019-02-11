//
//  SCNGeometrySource+GLTF.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import SceneKit

extension SCNGeometrySource {
    convenience init(accessor: GLTF.Accessor, semantic: SCNGeometrySource.Semantic, loader: VRMSceneLoader) throws {
        let (componentsPerVector, bytesPerComponent, vectorSize) = accessor.components()

        let (bufferView, dataStride): (Data, Int) = try {
            if let bufferViewIndex = accessor.bufferView {
                let bufferView = try loader.bufferView(withBufferViewIndex: bufferViewIndex)
                return (bufferView.bufferView, bufferView.stride ?? vectorSize)
            } else {
                return (Data(count: vectorSize * accessor.count), vectorSize)
            }
        }()

        self.init(data: bufferView,
                  semantic: semantic,
                  vectorCount: accessor.count,
                  usesFloatComponents: accessor.componentType == .float,
                  componentsPerVector: componentsPerVector,
                  bytesPerComponent: bytesPerComponent,
                  dataOffset: accessor.byteOffset,
                  dataStride: dataStride)
    }
}
