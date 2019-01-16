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

    var data: Data {
        switch self {
        case .aliciaSolid:
            let url = Bundle(for: BinaryGLTFTests.self).url(forResource: "Gab", withExtension: "vrm")!
            return try! Data(contentsOf: url)
        }
    }
}
