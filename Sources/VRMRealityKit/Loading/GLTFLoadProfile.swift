#if canImport(RealityKit)
import RealityKit
import VRMKit

/// What one flavour of document changes about a generic glTF load.
///
/// A plain glTF changes nothing, so ``GLTFDefaultLoadProfile`` implements none of it and
/// ``VRMLoadProfile`` is the whole of what loading a VRM adds. A profile describes the
/// document rather than the load in flight, so one is made per loader.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
protocol GLTFLoadProfile {
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

    /// What to render a material the shader chain could not build as, or nil to fail the
    /// load with the shader's error.
    func shadedMaterialFallback(for context: GLTFMaterialShaderContext,
                                error: any Error) -> GLTFShadedMaterial?

    /// The VRM 0.x Unity material property describing the material at `index`.
    func vrm0MaterialProperty(atMaterialIndex index: Int) -> VRM0.MaterialProperty?

    /// Textures the material at `index` samples that the glTF material slots do not name.
    func extraTextureIndices(ofMaterialAt index: Int) -> Set<Int>
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFLoadProfile {
    var supportedRequiredExtensions: Set<String> { [] }
    func validateRequiredExtensionsAreRenderable(of gltf: GLTF) throws {}
    func resolvedPrimitives(of mesh: GLTF.Mesh) -> [GLTF.Mesh.Primitive] { mesh.primitives }
    func headJoints(ofNodeAt nodeIndex: Int,
                    meshIndex: Int,
                    skinIndex: Int?,
                    hierarchy: GLTFNodeHierarchy) -> Set<UInt32> { [] }
    func shadedMaterialFallback(for context: GLTFMaterialShaderContext,
                                error: any Error) -> GLTFShadedMaterial? { nil }
    func vrm0MaterialProperty(atMaterialIndex index: Int) -> VRM0.MaterialProperty? { nil }
    func extraTextureIndices(ofMaterialAt index: Int) -> Set<Int> { [] }
}

/// A document read as the glTF core specification alone describes it.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
struct GLTFDefaultLoadProfile: GLTFLoadProfile {}
#endif
