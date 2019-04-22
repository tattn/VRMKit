//
//  Data+GLTF.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import Foundation

extension Data {
    init(buffer: GLTF.Buffer, relativeTo rootDirectory: URL?, vrm: VRM) throws {
        if let uri = buffer.uri {
            self = try Data(gltfUrlString: uri, relativeTo: rootDirectory)
        } else if let data = vrm.gltf.binaryBuffer {
            self = data
        } else {
            throw VRMError._dataInconsistent("failed to load buffers")
        }

        guard count >= buffer.byteLength else { throw VRMError._dataInconsistent("out of length \(count) >= \(buffer.byteLength)") }
    }

    init(gltfUrlString: String, relativeTo rootDirectory: URL?) throws {
        if let base64Str = gltfUrlString.retrievedBase64EncodedString() {
            self = try Data(base64Encoded: base64Str) ??? ._dataInconsistent("failed to load base64 data")
        } else {
            let url = URL(fileURLWithPath: gltfUrlString, relativeTo: rootDirectory)
            self = try Data(contentsOf: url)
        }
    }

    func subdata(offset: Int, size: Int, stride: Int, count: Int) -> Data {
        let dataSize = size * count
        if stride == size {
            if offset == 0 { return self }
            return subdata(in: offset..<offset + dataSize)
        }

        var indexData = Data(capacity: dataSize)

        indexData.withUnsafeMutableBytes { rawDst in
            guard let dst = rawDst.bindMemory(to: UInt8.self).baseAddress else { return }
            withUnsafeBytes { rawSrc in
                guard let src = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return }
                for pos in 0..<count {
                    let srcPos = stride * pos + offset
                    let dstPos = size * pos
                    memcpy(dst.advanced(by: dstPos), src.advanced(by: srcPos), size)
                }
            }
        }
        return indexData
    }
}

private extension String {
    func retrievedBase64EncodedString() -> String? {
        guard starts(with: "data:") else { return nil }
        return components(separatedBy: ";base64,").last
    }
}
