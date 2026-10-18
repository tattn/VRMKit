import Foundation
import Testing
import simd
import VRMKit
@testable import VRMKitRuntime

/// The arrays a model's pose lives in, which the runtimes write and skinning reads.
@Suite
struct GLTFPoseTests {
    /// Root → child → grandchild, each a unit along +x from its parent.
    private static func chain() -> GLTFPose {
        GLTFPose(children: [[1], [2], []],
                 locals: [GLTFNodeTransform(),
                          GLTFNodeTransform(translation: SIMD3(1, 0, 0)),
                          GLTFNodeTransform(translation: SIMD3(1, 0, 0))])
    }

    @Test
    func testAWriteMovesTheSubtreeInModelAndWorldSpace() {
        let pose = Self.chain()
        #expect(pose.modelMatrix(ofNode: 2).columns.3 == SIMD4(2, 0, 0, 1))

        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        pose.setLocalRotation(quarter, ofNode: 1)
        let grandchild = pose.modelMatrix(ofNode: 2).columns.3
        #expect(simd_distance(SIMD3(grandchild.x, grandchild.y, grandchild.z), SIMD3(1, 1, 0)) < 1e-5)
        #expect(abs(simd_dot(pose.modelRotation(ofNode: 2), quarter)) > 0.9999)

        pose.rootMatrix = simd_float4x4(translation: SIMD3(0, 0, 5))
        #expect(simd_distance(pose.worldPosition(ofNode: 2), SIMD3(1, 1, 5)) < 1e-5)
    }

    /// Skinning reads which nodes moved, so a write of what a node already holds is not one.
    @Test
    func testOnlyAChangedTransformCountsAsMoved() {
        let pose = Self.chain()
        pose.setLocalTranslation(SIMD3(1, 0, 0), ofNode: 1)
        #expect(!pose.hasNodesMovedForSkinning)

        pose.setLocalTranslation(SIMD3(2, 0, 0), ofNode: 1)
        pose.setLocalTranslation(SIMD3(3, 0, 0), ofNode: 1)
        #expect(pose.takeNodesMovedForSkinning() == [1])
        #expect(!pose.hasNodesMovedForSkinning)
    }

    /// A renderer keeping a copy of the pose hears every write but those it handed over itself.
    @Test
    func testTheWriteObserverHearsRuntimeWritesButNotAdoptedOnes() {
        let pose = Self.chain()
        var heard: [Int] = []
        pose.didWriteLocalTransform = { index, _ in heard.append(index) }

        pose.setLocalRotation(simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0)), ofNode: 2)
        pose.adoptLocalTransform(GLTFNodeTransform(translation: SIMD3(0, 3, 0)), ofNode: 1)
        #expect(heard == [2])
        // The adopted transform still moves the subtree and counts for skinning.
        #expect(pose.worldPosition(ofNode: 2).y > 2.9)
        #expect(Set(pose.takeNodesMovedForSkinning()) == [1, 2])
    }

    @Test
    func testPoseNodesWalkTheHierarchy() {
        let pose = Self.chain()
        let middle = pose.nodes[1]
        #expect(middle.runtimeParent === pose.nodes[0])
        #expect(middle.runtimeChildren.map(\.index) == [2])
        middle.setLocalRotation(simd_quatf(angle: 1, axis: SIMD3(1, 0, 0)))
        #expect(abs(simd_dot(pose.localTransform(ofNode: 1).rotation, middle.localRotation)) > 0.9999)
    }
}

private extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(translation, 1)
    }
}
