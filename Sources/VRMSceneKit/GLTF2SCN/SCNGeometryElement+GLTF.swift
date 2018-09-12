//
//  SCNGeometryElement+GLTF.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import SceneKit

extension SCNGeometryElement {
    convenience init(accessor: GLTF.Accessor, mode: GLTF.Mesh.Primitive.Mode, loader: VRMSceneLoader) throws {
        let primitiveType = try primitiveTypeOf(mode) ??? ._notSupported("\(mode) is not supported")
        let usesFloatComponents = accessor.componentType == .float
        let bytesPerComponent = bytes(of: accessor.componentType)

        if usesFloatComponents { throw VRMError._dataInconsistent("index accessor cannot use float components") }
        if accessor.type != .SCALAR { throw VRMError._dataInconsistent("accessor type is not SCALAR") }

        let (bufferView, dataStride): (Data, Int) = try {
            if let bufferViewIndex = accessor.bufferView {
                let bufferView = try loader.bufferView(withBufferViewIndex: bufferViewIndex)
                return (bufferView.bufferView, bufferView.stride ?? bytesPerComponent)
            } else {
                return (Data(count: bytesPerComponent * accessor.count), bytesPerComponent)
            }
        }()

        self.init(data: bufferView.subdata(offset: accessor.byteOffset, size: bytesPerComponent, stride: dataStride, count: accessor.count),
                  primitiveType: primitiveType,
                  primitiveCount: primitiveType.primitiveCount(ofCount: accessor.count),
                  bytesPerIndex: bytesPerComponent)
    }
}
