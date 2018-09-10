//
//  VRMSceneLoader+convenience.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import Foundation

extension VRMSceneLoader {
    public convenience init(withURL url: URL, rootDirectory: URL? = nil) throws {
        let vrm = try VRMLoader().load(withURL: url)
        self.init(vrm: vrm, rootDirectory: rootDirectory)
    }

    public convenience init(named: String, rootDirectory: URL? = nil) throws {
        let vrm = try VRMLoader().load(named: named)
        self.init(vrm: vrm, rootDirectory: rootDirectory)
    }

    public convenience init(withData data: Data, rootDirectory: URL? = nil) throws {
        let vrm = try VRMLoader().load(withData: data)
        self.init(vrm: vrm, rootDirectory: rootDirectory)
    }
}
