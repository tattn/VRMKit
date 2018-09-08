//
//  VRMError.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180909.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

public enum VRMError: Error {
    case notSupported(String)
    case notSupportedVersion(UInt32)
    case notSupportedChankType(UInt32)
}
