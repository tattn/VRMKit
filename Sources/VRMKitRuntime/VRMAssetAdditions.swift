import SIMDCompat
import VRMKit

/// What a caller adds to a VRM as it is read: morph targets of its own on the meshes, and
/// expressions driving them, such as a variant of an expression the model states.
///
/// What is added is part of the asset, so every renderer and instance built from it draws
/// and drives it as it does what the model states.
public struct VRMAssetAdditions: Sendable {
    /// The expressions the model offers after the ones it states. One sharing a key with a
    /// stated one replaces it. A morph bind reaches the added targets of a mesh at the
    /// indices after those the document declares (``morphTargets``).
    public var expressions: [VRMExpressionClip]
    /// The POSITION deltas of the targets appended to a mesh, one per vertex of it each,
    /// given the mesh as the document states it. Called off any actor, once per way the scene
    /// draws a glTF mesh (``GLTFAsset/Mesh/meshIndex``), and must answer each with the same
    /// number of targets. A mesh without vertices takes none.
    public var morphTargets: @Sendable (_ mesh: GLTFAsset.Mesh) -> [[SIMD3<Float>]]

    public init(expressions: [VRMExpressionClip],
                morphTargets: @escaping @Sendable (_ mesh: GLTFAsset.Mesh) -> [[SIMD3<Float>]]) {
        self.expressions = expressions
        self.morphTargets = morphTargets
    }
}
