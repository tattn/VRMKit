import SIMDCompat

/// One primitive decoded and conditioned for the build: its geometry, and what the build
/// would otherwise derive from it on the actor one vertex at a time.
package struct GLTFPreparedPrimitive: @unchecked Sendable {
    package let geometry: GLTFPrimitiveGeometry
    /// Whether ``firstPersonMask`` was cut for a node with head joints. A template drawn
    /// with the other cut derives its own mask.
    package let cutsHead: Bool
    package let firstPersonMask: FirstPersonPrimitiveMask
    /// Nil for an unskinned primitive.
    package let jointInfluences: GLTFJointInfluences?

    package init(geometry: GLTFPrimitiveGeometry,
                 cutsHead: Bool,
                 firstPersonMask: FirstPersonPrimitiveMask,
                 jointInfluences: GLTFJointInfluences?) {
        self.geometry = geometry
        self.cutsHead = cutsHead
        self.firstPersonMask = firstPersonMask
        self.jointInfluences = jointInfluences
    }
}

/// A skinned primitive's influences: four joints per vertex in the skin's joint order,
/// with the weights renormalized to sum to one.
package struct GLTFJointInfluences: Sendable {
    package let joints: [SIMD4<UInt32>]
    package let weights: [SIMD4<Float>]

    package init(joints: [SIMD4<UInt32>], weights: [SIMD4<Float>]) {
        self.joints = joints
        self.weights = weights
    }
}
