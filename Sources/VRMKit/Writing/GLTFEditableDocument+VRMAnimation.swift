import Foundation
import simd

/// The humanoid skeleton ``GLTFEditableDocument/addRestSkeleton(of:)`` copied into a
/// document: the node each bone became, and the node they all hang under.
public struct GLTFRestSkeleton: Sendable {
    public let root: GLTFNodeIndex
    public let bones: [HumanoidBone: GLTFNodeIndex]
}

extension GLTFEditableDocument {
    /// The `VRMC_vrm_animation` version an edit writes.
    static let writableAnimationSpecVersion = VRMAnimation.releasedSpecVersion

    /// Copies the rest skeleton of `vrm` as plain nodes: every humanoid bone and every
    /// node above one, each with the name and local transform it has in the model, so
    /// the copy rests exactly where the model does. Meshes, skins and extensions stay
    /// behind, which is what makes the result an animation's skeleton rather than a
    /// model.
    ///
    /// A `.vrma` is authored facing +Z as VRM 1.0 does, so the skeleton of a 0.x model,
    /// which faces -Z, is turned half a circle about Y at the root node this adds above
    /// it. The bones' own local transforms are untouched either way, so a rotation read
    /// off a bone of the model writes straight into a track of the copy.
    @discardableResult
    public mutating func addRestSkeleton(of vrm: VRM) throws -> GLTFRestSkeleton {
        let gltf = vrm.document.gltf
        let nodes = gltf.nodes
        let hierarchy = try GLTFNodeHierarchy(nodes: nodes)
        let boneNodes = vrm.boneNodes
        guard let hips = boneNodes[.hips], nodes.indices.contains(hips) else {
            throw VRMError._dataInconsistent("the humanoid rig names no hips node")
        }
        for (bone, node) in boneNodes where !nodes.indices.contains(node) {
            throw VRMError._dataInconsistent("the humanoid rig maps \(bone.rawValue) to node \(node), which does not exist")
        }

        let kept = Set(boneNodes.values.flatMap(hierarchy.lineage(of:)))
        // The skeleton faces the way the model does; a 0.x model is turned so that it
        // faces the way a `.vrma` is authored in.
        let facing = vrm.forwardDirection.z < 0
            ? simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
            : quat_identity_float

        return try atomically { document in
            let root = try document.addNode(name: vrm.name ?? "root",
                                            transform: GLTFNodeTransform(rotation: facing))
            var copied: [Int: GLTFNodeIndex] = [:]
            // Parents first, in the order the model lists its nodes, so the copy reads
            // like the model does.
            func copy(_ index: Int) throws -> GLTFNodeIndex {
                if let existing = copied[index] { return existing }
                let parent = try hierarchy.parent(at: index).map(copy) ?? root
                let node = nodes[index]
                let copy = try document.addNode(name: node.name,
                                                parent: parent,
                                                transform: GLTFNodeTransform(node: node))
                copied[index] = copy
                return copy
            }
            for index in nodes.indices where kept.contains(index) {
                _ = try copy(index)
            }
            return GLTFRestSkeleton(root: root, bones: boneNodes.compactMapValues { copied[$0] })
        }
    }

    /// Declares the document a VRM animation whose humanoid bones are the nodes given,
    /// which is what lets a reader retarget its animation onto any VRM. `hips` is the
    /// one bone the extension cannot go without.
    ///
    /// The `VRMC_vrm_animation` extension is added or, when the document carries one,
    /// its humanoid replaced with every other field of it left as it was.
    public mutating func setVRMAnimationHumanoid(_ bones: [HumanoidBone: GLTFNodeIndex]) throws {
        guard bones[.hips] != nil else {
            throw VRMError._invalidArgument("a VRM animation's humanoid needs a hips bone")
        }
        for (bone, node) in bones {
            do {
                try requireNode(at: node.rawValue)
            } catch {
                throw VRMError._invalidArgument("\(bone.rawValue) is mapped to \(node), which does not exist")
            }
        }
        if let existing = try rootExtensionObject(GLTFExtension.vrmAnimation.rawValue),
           existing["specVersion"] != nil {
            try requireWritableSpecVersion(of: existing, named: GLTFExtension.vrmAnimation.rawValue)
        }

        let humanBones = bones.reduce(into: JSONObject()) { object, entry in
            object[entry.key.rawValue] = ["node": .int(entry.value.rawValue)]
        }
        try updateRootExtension(GLTFExtension.vrmAnimation.rawValue) { extensionObject in
            extensionObject["specVersion"] = .string(Self.writableAnimationSpecVersion)
            extensionObject["humanoid"] = ["humanBones": .object(humanBones)]
        }
    }
}
