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

public enum Either<A: Codable, B: Codable>: Codable {
    case int(Int)
    case double(Double)

    public var value: Double {
        get {
            switch self {
            case .double(let d):
                return d
            case .int(let i):
                return Double(i)
            }
        }
    }
    
    public init(from decoder: Decoder) throws {
        if let i = try? decoder.singleValueContainer().decode(Int.self) {
            self = .int(i)
        } else if let d = try? decoder.singleValueContainer().decode(Double.self) {
            self = .double(d)
        } else {
            throw Error.neitherDecodable
        }
    }
    
    public enum Error: Swift.Error {
        case neitherDecodable
    }
}

func decodeDouble<T: CodingKey>(key: T, container: KeyedDecodingContainer<T>) throws -> Double {
    return try (try? container.decode(Double.self, forKey: key)) ?? Double(try container.decode(Int.self, forKey: key))
}
