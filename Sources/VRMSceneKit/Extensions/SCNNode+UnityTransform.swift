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
    private let base: Base
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
    func transformPoint(_ position: simd_float3) -> simd_float3 {
        base.simdConvertPosition(position, to: nil)
    }
    
    func inverseTransformPoint(_ position: simd_float3) -> simd_float3 {
        base.simdConvertPosition(position, from: nil)
    }
    
    var localRotation: simd_quatf {
        get { base.simdOrientation }
        set { base.simdOrientation = newValue }
    }
    
    var position: simd_float3 {
        get { base.simdWorldPosition }
        set { base.simdWorldPosition = newValue }
    }
    
    var localPosition: simd_float3 {
        get { base.simdPosition }
        set { base.simdPosition = newValue }
    }
    
    var rotation: simd_quatf {
        get { base.simdWorldOrientation }
        set { base.simdWorldOrientation = newValue }
    }
    
    var childCount: Int {
        base.childNodes.count
    }
    
    var localToWorldMatrix: simd_float4x4 {
        if let parent = base.parent {
            return parent.utx.localToWorldMatrix * base.simdTransform
        } else {
            return base.simdTransform
        }
    }
    
    var worldToLocalMatrix: simd_float4x4 {
        localToWorldMatrix.inverse
    }
    
    var lossyScale: simd_float3 {
        if let parent = base.parent {
            return parent.utx.lossyScale * base.simdScale
        } else {
            return base.simdScale
        }
    }
}
