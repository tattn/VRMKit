//
//  GlobalFunction.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import VRMKit
import Foundation

infix operator ???

func ???<T>(lhs: T?,
            error: @autoclosure () -> VRMError) throws -> T {
    guard let value = lhs else { throw error() }
    return value
}
