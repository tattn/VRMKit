//
//  GlobalFunction.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

func read<T>(_ data: Data, offset: inout Int, size: Int) throws -> T {
    defer { offset += size }
    return try data.subdata(in: offset..<(offset+size)).withUnsafeBytes {
        try $0.bindMemory(to: T.self).baseAddress?.pointee ??? VRMError.dataInconsistent("failed to read data")
    }
}

func read(_ data: Data, offset: inout Int, size: Int) -> Data {
    defer { offset += size }
    return data.subdata(in: offset..<(offset+size))
}

infix operator ???

func ???<T>(lhs: T?,
            error: @autoclosure () -> VRMError) throws -> T {
    guard let value = lhs else { throw error() }
    return value
}
