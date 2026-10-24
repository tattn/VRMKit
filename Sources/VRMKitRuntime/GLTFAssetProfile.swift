import VRMKit

/// What one flavour of document changes about reading a generic glTF.
///
/// A plain glTF changes nothing, so ``GLTFDefaultAssetProfile`` implements none of it and
/// ``VRMAssetProfile`` is the whole of what reading a VRM adds. A profile describes the
/// document rather than any one load, so one is made per document.
package protocol GLTFAssetProfile: Sendable {
    /// Extensions this profile implements, on top of the generic glTF ones, to satisfy
    /// `extensionsRequired`.
    var supportedRequiredExtensions: Set<String> { get }

    /// Fails the load when the document leans on one of those extensions past what is
    /// implemented of it. Called once the required names are known to be implemented.
    func validateRequiredExtensionsAreRenderable(of gltf: GLTF) throws

    /// The primitives a mesh is built from, which VRM reads differently from glTF.
    func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive]

    /// The joints of `skinIndex` whose triangles a first-person camera drops from the
    /// mesh the node at `nodeIndex` draws.
    func headJoints(ofNodeAt nodeIndex: Int,
                    meshIndex: Int,
                    skinIndex: Int?,
                    hierarchy: GLTFNodeHierarchy) -> Set<UInt32>

    /// The VRM 0.x Unity material property describing the material at `index`.
    func vrm0MaterialProperty(atMaterialIndex index: Int) -> VRM0.MaterialProperty?

    /// Textures the material at `index` samples that the glTF material slots do not name.
    func extraTextureIndices(ofMaterialAt index: Int) -> Set<Int>
}

extension GLTFAssetProfile {
    package var supportedRequiredExtensions: Set<String> { [] }
    package func validateRequiredExtensionsAreRenderable(of gltf: GLTF) throws {}
    package func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] { mesh.primitives }
    package func headJoints(ofNodeAt nodeIndex: Int,
                            meshIndex: Int,
                            skinIndex: Int?,
                            hierarchy: GLTFNodeHierarchy) -> Set<UInt32> { [] }
    package func vrm0MaterialProperty(atMaterialIndex index: Int) -> VRM0.MaterialProperty? { nil }
    package func extraTextureIndices(ofMaterialAt index: Int) -> Set<Int> { [] }
}

/// A document read as the glTF core specification alone describes it.
package struct GLTFDefaultAssetProfile: GLTFAssetProfile {
    package init() {}
}
