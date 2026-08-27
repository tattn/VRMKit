import Testing
import simd
import VRMKit
@testable import VRMKitRuntime

/// Composing world transforms down a chain, which is what lets a rig solve a
/// whole spring off one world transform read from the renderer.
@Suite
struct SpringBoneWorldTransformTests {
    /// A non-uniform scale above a rotation shears the matrix below it, which no
    /// translation-rotation-scale triple holds, so composing one is the only way
    /// a chain lands where the scene graph puts it.
    @Test
    func testComposingAChainMatchesTheSceneGraphUnderANonUniformScale() {
        let root = TestRuntimeNode(translation: SIMD3(0.3, -0.2, 0.1),
                                   rotation: simd_quatf(angle: .pi / 5, axis: SIMD3(0, 0, 1)),
                                   scale: SIMD3(2, 1, 1))
        let child = root.addChild(
            TestRuntimeNode(translation: SIMD3(0, 1, 0),
                            rotation: simd_quatf(angle: .pi / 3, axis: simd_normalize(SIMD3(1, 1, 0))))
        )
        let grandchild = child.addChild(
            TestRuntimeNode(translation: SIMD3(0.4, 0.7, -0.2),
                            rotation: simd_quatf(angle: -.pi / 4, axis: SIMD3(1, 0, 0)))
        )

        let composedChild = child.worldTransform(under: root.worldTransform)
        let composedGrandchild = grandchild.worldTransform(under: composedChild)

        // The node's own world transform is the plain product of the local
        // matrices above it, which is what a composed one has to land on.
        #expect(composedChild.matrix.isApproximatelyEqual(to: child.worldMatrix))
        #expect(composedGrandchild.matrix.isApproximatelyEqual(to: grandchild.worldMatrix))
    }
}

private extension simd_float4x4 {
    func isApproximatelyEqual(to other: simd_float4x4, tolerance: Float = 1e-5) -> Bool {
        (0..<4).allSatisfy { simd_distance(self[$0], other[$0]) < tolerance }
    }
}
