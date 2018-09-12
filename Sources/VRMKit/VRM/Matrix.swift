//
//  Matrix.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

extension GLTF {
    public struct Matrix: Codable {
        public let values: [Float]

        public static var identity: Matrix {
            return .init(values: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        }
    }
}
