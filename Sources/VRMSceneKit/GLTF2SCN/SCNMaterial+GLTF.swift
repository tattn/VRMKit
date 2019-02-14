//
//  SCNMaterial+GLTF.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import SceneKit
import SpriteKit

extension SCNMaterial {
    convenience init(material: GLTF.Material, loader: VRMSceneLoader) throws {
        self.init()
        name = material.name
//        lightingModel = .physicallyBased
        lightingModel = .constant // FIXME:
        isDoubleSided = material.doubleSided
        isLitPerPixel = false
        writesToDepthBuffer = material.alphaMode != .BLEND

        var shader: VRM.MaterialProperty.Shader?

        if let name = name, let property = loader.vrm.materialPropertyNameMap[name] {
            shader = property.vrmShader
            // FIXME/TODO: https://dwango.github.io/vrm/vrm_spec/#vrm%E3%81%8C%E6%8F%90%E4%BE%9B%E3%81%99%E3%82%8B%E3%82%B7%E3%82%A7%E3%83%BC%E3%83%80%E3%83%BC
            if shader == .unlitTransparent {
                blendMode = .alpha
                writesToDepthBuffer = false
            } else if property.keywordMap["_ALPHAPREMULTIPLY_ON"] ?? false {
                blendMode = .alpha
            } else {
                blendMode = blendMode(of: material.alphaMode)
            }
        } else {
            blendMode = blendMode(of: material.alphaMode)
        }

        if let pbr = material.pbrMetallicRoughness {
            // https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#metallic-roughness-material

            if let baseTexture = pbr.baseColorTexture {
                try diffuse.setTextureInfo(baseTexture, loader: loader)
                if shader == .mToon {
                    multiply.contents = pbr.baseColorFactor.createSKColor()
                }
            } else {
                diffuse.contents = pbr.baseColorFactor.createSKColor()
            }

            if let metallicTexture = pbr.metallicRoughnessTexture {
                try metalness.setTextureInfo(metallicTexture, loader: loader)
                try roughness.setTextureInfo(metallicTexture, loader: loader)

                let image = try metalness.contents as? UIImage ??? ._dataInconsistent("failed to load texture image")
                let (metalTexture, roughTexture) = try createMetallicRoughnessTexture(from: image)
                metalness.contents = metalTexture
                roughness.contents = roughTexture
            } else {
                metalness.contents = SKColor(white: CGFloat(pbr.metallicFactor), alpha: 1)
                roughness.contents = SKColor(white: CGFloat(pbr.roughnessFactor), alpha: 1)
            }
        }

        if let normalTexture = material.normalTexture {
            try normal.setTextureInfo(normalTexture, loader: loader)
        }

        if let occlusionTexture = material.occlusionTexture {
            try ambientOcclusion.setTextureInfo(occlusionTexture, loader: loader)
            ambientOcclusion.intensity = CGFloat(occlusionTexture.strength)
        }

        if let emissiveTexture = material.emissiveTexture {
            try emission.setTextureInfo(emissiveTexture, loader: loader)
        }
    }

    private func createMetallicRoughnessTexture(from uiImage: UIImage) throws -> (metal: UIImage, rough: UIImage) {
        let image = try uiImage.cgImage ??? ._dataInconsistent("failed to get cgImage")

        // https://github.com/KhronosGroup/glTF/blob/master/specification/2.0/README.md#pbrmetallicroughnessmetallicroughnesstexture

        let pixelCount = image.width * image.height
        let bitsPerComponent = 8
        let componentsPerPixel = 4 // RGBA
        let srcBytesPerPixel = bitsPerComponent * componentsPerPixel / 8
        let srcDataSize = pixelCount * srcBytesPerPixel

        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: srcDataSize)
        let metalPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let roughPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        defer {
            ptr.deallocate()
            metalPtr.deallocate()
            roughPtr.deallocate()
        }

        let context = try CGContext(
            data: UnsafeMutableRawPointer(ptr),
            width: image.width,
            height: image.height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: srcBytesPerPixel * image.width,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ??? ._dataInconsistent("failed to create cgcontext")
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        for dstPos in 0..<pixelCount {
            let srcPos = dstPos * srcBytesPerPixel
            metalPtr[dstPos] = ptr[srcPos + 2] // blue
            roughPtr[dstPos] = ptr[srcPos + 1] // green
        }

        let metalImage = try createGraySpaceImage(width: image.width,
                                                  height: image.height,
                                                  dataPointer: metalPtr)

        let roughImage = try createGraySpaceImage(width: image.width,
                                                  height: image.height,
                                                  dataPointer: roughPtr)
        return (metalImage, roughImage)
    }

    private func createGraySpaceImage(width: Int,
                                      height: Int,
                                      dataPointer: UnsafeMutablePointer<UInt8>) throws -> UIImage {
        let data = try CFDataCreate(nil, dataPointer, width * height) ??? ._dataInconsistent("failed to create CFDataCreate")
        let provider = try CGDataProvider(data: data) ??? ._dataInconsistent("failed to create CGDataProvider")
        return UIImage(cgImage:
            try CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width * 1,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent) ??? ._dataInconsistent("failed to create CGImage")
        )
    }

    private func blendMode(of alphaMode: GLTF.Material.AlphaMode) -> SCNBlendMode {
        // FIXME/TODO: https://dwango.github.io/vrm/vrm_spec/#vrm%E3%81%8C%E6%8F%90%E4%BE%9B%E3%81%99%E3%82%8B%E3%82%B7%E3%82%A7%E3%83%BC%E3%83%80%E3%83%BC
        switch alphaMode {
        case .OPAQUE: return .replace
        case .BLEND: return .alpha // FIXME/TODO: blend shader
        case .MASK: return .alpha // FIXME/TODO: alphaCutoff shader
        }
    }
}
