//
//  VRM+Extension.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 2019/02/15.
//  Copyright © 2019 tattn. All rights reserved.
//

import Foundation

public extension VRM.MaterialProperty {
    var vrmShader: Shader? {
        return Shader(rawValue: shader)
    }

    enum Shader: String {
        case mToon = "VRM/MToon"
        case unlitTransparent = "VRM/UnlitTransparent"
    }
}
