//
//  VRM+Extension.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 2019/02/15.
//  Copyright © 2019 tattn. All rights reserved.
//

import Foundation

public extension VRM.MaterialProperty {
    public var vrmShader: Shader? {
        return Shader(rawValue: shader)
    }

    public enum Shader: String {
        case mToon = "VRM/MToon"
        case unlitTransparent = "VRM/UnlitTransparent"
    }
}
