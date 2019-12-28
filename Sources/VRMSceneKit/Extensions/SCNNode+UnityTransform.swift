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
        fatalError()
    }
    
    func inverseTransformPoint(_ position: SCNVector3) -> SCNVector3 {
        fatalError()
    }
    
    var localRotation: SCNQuaternion {
        get { base.rotation }
        set { base.rotation = newValue }
    }
    
    var position: SCNVector3 {
        base.worldPosition
    }
    
    var localPosition: SCNVector3 {
        base.position
    }
    
    var rotation: SCNQuaternion {
        get { fatalError() }
        set { fatalError() }
    }
    
    var transform: UnityTransform<SCNNode> {
        self
    }
    
    func traverse() -> [UnityTransform<SCNNode>] {
        fatalError()
    }
    
    var childCount: Int {
        base.childNodes.count
    }
    
    var worldToLocalMatrix: SCNMatrix4 {
        fatalError()
    }
    
    var lossyScale: SCNVector3 {
        fatalError()
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
