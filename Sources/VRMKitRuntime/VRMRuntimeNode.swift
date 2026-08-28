import simd
import VRMKit

/// A scene graph node the VRM runtimes pose, and the whole of what a renderer
/// has to provide.
///
/// The runtimes read local transforms and write local rotations, and read a
/// world transform only for what they cannot derive themselves, so swinging a
/// spring of a hundred joints costs a hundred local reads rather than a hundred
/// walks up to the root.
package protocol VRMRuntimeNode: AnyObject {
    /// This same type. A renderer's node type is not final, and a protocol a
    /// non-final class conforms to cannot name `Self` in a stored position.
    associatedtype RuntimeNode: VRMRuntimeNode where RuntimeNode.RuntimeNode == RuntimeNode

    var runtimeParent: RuntimeNode? { get }
    var runtimeChildren: [RuntimeNode] { get }

    /// The node's transform in its parent's space.
    var localMatrix: simd_float4x4 { get }
    /// The rotation of that transform, which the solvers compose on its own.
    var localRotation: simd_quatf { get }

    /// Writes the rotation back, leaving the translation and the scale alone.
    func setLocalRotation(_ rotation: simd_quatf)

    var worldMatrix: simd_float4x4 { get }
    var worldRotation: simd_quatf { get }
}

extension VRMRuntimeNode {
    /// Writes `rotation` back unless the node already holds it, and answers whether it
    /// moved: a renderer re-solves its skin pose only for the nodes that did. A
    /// quaternion and its negation are the same rotation, so neither counts as a move.
    func setLocalRotationIfMoved(_ rotation: simd_quatf) -> Bool {
        let current = localRotation.vector
        guard current != rotation.vector, current != -rotation.vector else { return false }
        setLocalRotation(rotation)
        return true
    }

    var worldTransform: SpringBoneWorldTransform {
        SpringBoneWorldTransform(matrix: worldMatrix, rotation: worldRotation)
    }

    var worldPosition: SIMD3<Float> { worldMatrix.translation }

    /// This node's world transform composed under an already solved parent one,
    /// which is what lets a rig walk a chain without asking the renderer where
    /// each node ended up.
    func worldTransform(under parent: SpringBoneWorldTransform) -> SpringBoneWorldTransform {
        SpringBoneWorldTransform(matrix: parent.matrix * localMatrix,
                                 rotation: parent.rotation * localRotation)
    }
}
