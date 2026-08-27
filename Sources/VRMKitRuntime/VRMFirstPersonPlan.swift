import VRMKit

/// How each mesh of a model is drawn by a first-person camera, and which joints
/// of each skin the head draws through.
///
/// Both VRM versions leave a mesh nothing says otherwise about `auto`.
/// ``FirstPersonAutoMask`` is the cut; this decides where it applies.
package struct VRMFirstPersonPlan: Sendable {
    /// The node the camera sits on, whose bones an `auto` mesh loses. Nil for a
    /// model that rigs no head.
    package let headNode: Int?
    /// What the model annotates, under the index it annotates it by. glTF lets
    /// two nodes draw one mesh, and VRM 1.0 annotates the node, so the two
    /// versions cannot share a key.
    private enum Annotations: Sendable {
        /// VRM 0.x, keyed by mesh index.
        case byMesh([Int: FirstPersonAnnotationType])
        /// VRM 1.0, keyed by node index.
        case byNode([Int: FirstPersonAnnotationType])
    }

    private let annotations: Annotations
    /// Skin index -> the joints of it the head draws through.
    private let headJointsBySkin: [Int: Set<UInt32>]

    package init(vrm: VRM, gltf: GLTF, hierarchy: GLTFNodeHierarchy) {
        let nodes = gltf.nodes ?? []
        switch vrm {
        case .v0(let vrm0):
            // VRM 0.x names the bone itself, and writes -1 to leave it to the humanoid.
            let bone = vrm0.firstPerson.firstPersonBone
            headNode = nodes.indices.contains(bone) ? bone : vrm.nodeIndex(of: .head)
            var byMesh: [Int: FirstPersonAnnotationType?] = [:]
            for annotation in vrm0.firstPerson.meshAnnotations {
                // A flag VRM 0.x does not name leaves the mesh at `auto`.
                byMesh[annotation.mesh] = FirstPersonAnnotationType(vrm0Flag: annotation.firstPersonFlag)
            }
            annotations = .byMesh(byMesh.compactMapValues { $0 })
        case .v1(let vrm1):
            headNode = vrm.nodeIndex(of: .head)
            var byNode: [Int: FirstPersonAnnotationType] = [:]
            for annotation in vrm1.firstPerson?.meshAnnotations ?? [] {
                byNode[annotation.node] = FirstPersonAnnotationType(vrm1Type: annotation.type)
            }
            annotations = .byNode(byNode)
        }

        var headJoints: [Int: Set<UInt32>] = [:]
        if let headNode {
            for (index, skin) in (gltf.skins ?? []).enumerated() {
                let joints = FirstPersonAutoMask.headJoints(skinJoints: skin.joints,
                                                            headNode: headNode,
                                                            hierarchy: hierarchy)
                if !joints.isEmpty { headJoints[index] = joints }
            }
        }
        headJointsBySkin = headJoints
    }

    /// How the node at `nodeIndex` draws the mesh at `meshIndex`, `auto` for one
    /// nothing annotates.
    package func annotation(ofNodeAt nodeIndex: Int, meshIndex: Int) -> FirstPersonAnnotationType {
        switch annotations {
        case .byMesh(let byMesh): byMesh[meshIndex] ?? .auto
        case .byNode(let byNode): byNode[nodeIndex] ?? .auto
        }
    }

    /// The joints an `auto` mesh loses the triangles of, empty for one it keeps.
    package func headJoints(ofNodeAt nodeIndex: Int, meshIndex: Int, skinIndex: Int?) -> Set<UInt32> {
        guard let skinIndex,
              annotation(ofNodeAt: nodeIndex, meshIndex: meshIndex) == .auto else { return [] }
        return headJointsBySkin[skinIndex] ?? []
    }
}
