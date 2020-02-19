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
    public convenience init(withURL url: URL, options: VRMSceneLoaderOptions = .default) throws {
        let vrm = try VRMLoader().load(withURL: url)
        self.init(vrm: vrm, options: options)
    }

    public convenience init(named: String, options: VRMSceneLoaderOptions = .default) throws {
        let vrm = try VRMLoader().load(named: named)
        self.init(vrm: vrm, options: options)
    }

    public convenience init(withData data: Data, options: VRMSceneLoaderOptions = .default) throws {
        let vrm = try VRMLoader().load(withData: data)
        self.init(vrm: vrm, options: options)
    }
}
