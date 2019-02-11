//
//  VRMScene.swift
//  VRMSceneKit
//
//  Created by Tatsuya Tanaka on 20180911.
//  Copyright © 2018年 tattn. All rights reserved.
//

import SceneKit
import VRMKit

open class VRMScene: SCNScene {
    public let vrm: VRM
    public let humanoid = Humanoid()
    let sceneData: SceneData

    var blendShapeClips: [BlendShapeKey: BlendShapeClip] = [:]

    init(vrm: VRM, sceneData: SceneData) {
        self.vrm = vrm
        self.sceneData = sceneData
        super.init()
    }

    @available(*, unavailable)
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setUpHumanoid() {
        humanoid.setUp(humanoid: vrm.humanoid, nodes: sceneData.nodes)
    }

    func setUpBlendShapes() {
        blendShapeClips = vrm.blendShapeMaster.blendShapeGroups
            .map { group in
                let blendShapeBinding: [BlendShapeBinding] = group.binds?
                    .compactMap {
                        guard let mesh = sceneData.meshes[$0.mesh] else {
                            return nil
                        }
                        return BlendShapeBinding(mesh: mesh, index: $0.index, weight: $0.weight)
                    } ?? []
                return BlendShapeClip(name: group.name,
                    preset: BlendShapePreset(name: group.presetName),
                    values: blendShapeBinding,
                    isBinary: group.isBinary)
            }
            .reduce(into: [:]) { result, clip in
                result[clip.key] = clip
            }
    }

    /// Set blend shapes to avatar
    ///
    /// - Parameters:
    ///   - value: a weight of the blend shape (0.0 <= value <= 1.0)
    ///   - key: a key of the blend shape
    public func setBlendShape(value: CGFloat, for key: BlendShapeKey) {
        guard let clip = blendShapeClips[key] else { return }
        let value: CGFloat = clip.isBinary ? round(value) : value
        for binding in clip.values {
            let weight = CGFloat(binding.weight / 100.0)
            for primitive in binding.mesh.childNodes {
                guard let morpher = primitive.morpher else { continue }
                morpher.setWeight(weight * value, forTargetAt: binding.index)
            }
        }
    }

    /// Get a weight of the blend shape
    ///
    /// - Parameter key: a key of the blend shape
    /// - Returns: a weight of the blend shape
    public func blendShape(for key: BlendShapeKey) -> CGFloat {
        guard let clip = blendShapeClips[key],
            let binding = clip.values.first,
            let morpher = binding.mesh.childNodes.lazy.compactMap({ $0.morpher }).first else { return 0 }
        return morpher.weight(forTargetAt: binding.index)
    }
}
