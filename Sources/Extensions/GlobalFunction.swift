//
//  GlobalFunction.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

func read<T>(_ data: Data, offset: inout Int, size: Int) -> T {
    defer { offset += size }
    return data.subdata(in: offset..<(offset+size)).withUnsafeBytes { $0.pointee }
}

func read(_ data: Data, offset: inout Int, size: Int) -> Data {
    defer { offset += size }
    return data.subdata(in: offset..<(offset+size))
}
