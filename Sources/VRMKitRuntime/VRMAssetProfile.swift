import Foundation
import VRMKit

/// What reading a VRM adds to reading a generic glTF: the VRM extensions it implements,
/// VRM 0.x material properties, the first-person cut and VRM's morph target sharing.
///
/// What a VRM adds on top of the scene, the humanoid, the expressions, the constraints
/// and the spring bones, is ``VRMInstance``'s.
package final class VRMAssetProfile: GLTFAssetProfile, Sendable {
    package let vrm: VRM
    private let firstPersonPlan = Locked<VRMFirstPersonPlan?>(nil)

    package init(vrm: VRM) {
        self.vrm = vrm
    }

    /// The VRM extensions this implements, which is a question of the model's version:
    /// 0.x states its spring bones inside `VRM` and knows nothing of node constraints,
    /// so nothing here would read the 1.0 extensions off it.
    package var supportedRequiredExtensions: Set<String> {
        switch vrm {
        case .v0:
            [GLTFExtension.vrm0.rawValue]
        case .v1:
            [GLTFExtension.vrm1.rawValue,
             GLTFExtension.springBone.rawValue,
             GLTFExtension.nodeConstraint.rawValue]
        }
    }

    /// A required VRM extension has to be one this reads, not merely one it knows the
    /// name of: an unmodeled spec version is read as no spring bones and no constraints
    /// at all, which is the load a document requiring them says must not happen.
    package func validateRequiredExtensionsAreRenderable(of gltf: GLTF) throws {
        // A 0.x model requiring either is refused by name, since it claims neither.
        guard case .v1(let vrm1) = vrm else { return }
        if gltf.extensionsRequired.contains(GLTFExtension.springBone.rawValue) {
            try validateSpringBonesAreReadable(vrm1.springBone)
        }
        if gltf.extensionsRequired.contains(GLTFExtension.nodeConstraint.rawValue) {
            try validateNodeConstraintsAreReadable(of: gltf)
        }
    }

    private func validateSpringBonesAreReadable(_ springBone: VRM1.SpringBone?) throws {
        guard let springBone else {
            throw VRMError._dataInconsistent(
                "this model requires the \(GLTFExtension.springBone.rawValue) extension and carries none"
            )
        }
        guard VRM1.SpringBone.supports(specVersion: springBone.specVersion) else {
            throw VRMError._notSupported(
                "this model requires the \(GLTFExtension.springBone.rawValue) extension, "
                + "and this package does not read its spec version "
                + "\(springBone.specVersion ?? "(unstated)")"
            )
        }
    }

    private func validateNodeConstraintsAreReadable(of gltf: GLTF) throws {
        for (index, gltfNode) in gltf.nodes.enumerated() {
            guard let nodeConstraint = gltfNode.extensions?.nodeConstraint,
                  !GLTF.Node.NodeExtensions.NodeConstraint.supports(specVersion: nodeConstraint.specVersion) else {
                continue
            }
            throw VRMError._notSupported(
                "this model requires the \(GLTFExtension.nodeConstraint.rawValue) extension, and this package "
                + "does not read the spec version \(nodeConstraint.specVersion ?? "(unstated)") node \(index) states"
            )
        }
    }

    /// A primitive carrying no morph targets of its own morphs with those of whichever
    /// primitive of the mesh carries them for its POSITION accessor.
    package func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] {
        let shared = mesh.morphTargetsByPositionAccessor()
        guard !shared.isEmpty else { return mesh.primitives }
        return mesh.primitives.map { primitive in
            guard primitive.targets?.isEmpty ?? true,
                  let position = primitive.attributes[.POSITION],
                  let targets = shared[position] else {
                return primitive
            }
            var primitive = primitive
            primitive.targets = targets
            return primitive
        }
    }

    package func headJoints(ofNodeAt nodeIndex: Int,
                            meshIndex: Int,
                            skinIndex: Int?,
                            hierarchy: GLTFNodeHierarchy) -> Set<UInt32> {
        firstPerson(hierarchy: hierarchy).headJoints(ofNodeAt: nodeIndex,
                                                     meshIndex: meshIndex,
                                                     skinIndex: skinIndex)
    }

    /// Which meshes a first-person camera cuts, resolved once per model.
    private func firstPerson(hierarchy: GLTFNodeHierarchy) -> VRMFirstPersonPlan {
        firstPersonPlan.withLock { plan in
            if let plan { return plan }
            let made = VRMFirstPersonPlan(vrm: vrm, gltf: vrm.document.gltf, hierarchy: hierarchy)
            plan = made
            return made
        }
    }

    package func vrm0MaterialProperty(atMaterialIndex index: Int) -> VRM0.MaterialProperty? {
        vrm.vrm0MaterialProperty(at: index)
    }

    /// VRM 0.x writes a material's MToon textures in the root extension entry beside it
    /// rather than on the material, so the glTF slots alone would miss them.
    package func extraTextureIndices(ofMaterialAt index: Int) -> Set<Int> {
        Set((vrm0MaterialProperty(atMaterialIndex: index)?.textureProperties ?? [:]).values)
    }
}
