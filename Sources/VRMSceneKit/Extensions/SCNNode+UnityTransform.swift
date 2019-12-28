//
//  SCNNode+UnityTransform.swift
//  VRMSceneKit
//
//  Created by Tomoya Hirano on 2019/12/28.
//  Copyright © 2019 tattn. All rights reserved.
//

import SceneKit

public protocol UnityTransformCompatible {
    associatedtype CompatibleType
    
    var utx: CompatibleType { get }
}

public final class UnityTransform<Base> {
    let base: Base
    public init(_ base: Base) {
        self.base = base
    }
}

public extension UnityTransformCompatible {
    var utx: UnityTransform<Self> {
        return UnityTransform(self)
    }
}

extension SCNNode: UnityTransformCompatible {}

extension UnityTransform where Base == SCNNode {
    func transformPoint(_ position: SCNVector3) -> SCNVector3 {
        base.convertPosition(position, to: nil)
    }
    
    func inverseTransformPoint(_ position: SCNVector3) -> SCNVector3 {
        base.parent!.convertVector(position, from: nil)
    }
    
    var localRotation: SCNQuaternion {
        get { base.orientation }
        set { base.orientation = newValue }
    }
    
    var position: SCNVector3 {
        get { base.worldPosition }
        set { base.worldPosition = newValue }
    }
    
    var localPosition: SCNVector3 {
        get { base.position }
        set { base.position = newValue }
    }
    
    var rotation: SCNQuaternion {
        get { base.worldOrientation }
        set { base.worldOrientation = newValue }
    }
    
    var childCount: Int {
        base.childNodes.count
    }
    
    var worldToLocalMatrix: SCNMatrix4 {
        base.transform
    }
    
    var lossyScale: SCNVector3 {
        base.scale
    }
}


extension SCNNode: Sequence {
    public func makeIterator() -> ChildNodeIterator {
        SCNNode.ChildNodeIterator(self)
    }
}

extension SCNNode {
    public struct ChildNodeIterator: IteratorProtocol {
        private let node: SCNNode
        private var index: Int = 0

        init(_ node: SCNNode) {
            self.node = node
        }

        mutating public func next() -> SCNNode? {
            defer { index += 1 }
            guard index < node.childNodes.count else { return nil }
            return node.childNodes[index]
        }
    }
}
