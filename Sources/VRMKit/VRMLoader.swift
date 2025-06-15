//
//  VRMLoader.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation
import SceneKit

open class VRMLoader {
    public init() {}

    open func load(named: String) throws -> VRM {
        guard let url = Bundle.main.url(forResource: named, withExtension: nil) else {
            throw URLError(.fileDoesNotExist)
        }
        return try load(withURL: url)
    }

    open func load(withURL url: URL) throws -> VRM {
        let data = try Data(contentsOf: url)
        return try load(withData: data)
    }

    open func load(withData data: Data) throws -> VRM {
        return try VRM(data: data)
    }

    open func load<T: VRMFile>(_ type: T.Type = T.self, named: String) throws -> T {
        guard let url = Bundle.main.url(forResource: named, withExtension: nil) else {
            throw URLError(.fileDoesNotExist)
        }
        return try load(type, withURL: url)
    }

    open func load<T: VRMFile>(_ type: T.Type = T.self, withURL url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try load(type, withData: data)
    }

    open func load<T: VRMFile>(_ type: T.Type = T.self, withData data: Data) throws -> T {
        return try T(data: data)
    }
}
