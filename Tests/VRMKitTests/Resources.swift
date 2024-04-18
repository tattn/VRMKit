//
//  Resources.swift
//  VRMKitTests
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

enum Resources {
    case aliciaSolid
    case seedSan

    var data: Data {
        switch self {
        case .aliciaSolid:
            let url = Bundle.module.url(forResource: "AliciaSolid", withExtension: "vrm")!
            return try! Data(contentsOf: url)
        case .seedSan:
            let url = Bundle.module.url(forResource: "Seed-san", withExtension: "vrm")!
            return try! Data(contentsOf: url)
        }
    }
}
