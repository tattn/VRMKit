//
//  RenderUpdatable.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2019/12/29.
//  Copyright © 2019 tattn. All rights reserved.
//

import Foundation

public protocol RenderUpdatable {
    func update(at time: TimeInterval)
}
