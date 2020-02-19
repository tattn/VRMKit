//
//  UIImage+GLTF.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import UIKit

extension UIImage {
    convenience init(image: GLTF.Image, relativeTo rootDirectory: URL?, loader: VRMSceneLoader, scale: CGFloat) throws {
        let data: Data
        if let uri = image.uri {
            data = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let bufferViewIndex = image.bufferView {
            data = try loader.bufferView(withBufferViewIndex: bufferViewIndex).bufferView
        } else {
            throw VRMError._dataInconsistent("failed to load images")
        }
        
        let cgImage: CGImage? = {
            guard let ciImage = CIImage(data: data)?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
            return CIContext().createCGImage(ciImage, from: ciImage.extent)
        }()
        self.init(cgImage: try cgImage ??? ._dataInconsistent("failed to load image"))
    }
}
