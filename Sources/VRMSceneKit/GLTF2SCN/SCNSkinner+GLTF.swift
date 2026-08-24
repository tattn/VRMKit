import VRMKit
import SceneKit

extension SCNSkinner {
    convenience init(primitiveGeometry: SCNGeometry,
                     bones: [SCNNode],
                     boneInverseBindTransform ibm: [InverseBindMatrix]?) throws {
        let weights = try primitiveGeometry.sources(for: .boneWeights)[safe: 0] ??? .dataInconsistent("boneWeights is not found")
        let indices = try primitiveGeometry.sources(for: .boneIndices)[safe: 0] ??? .dataInconsistent("boneIndices is not found")
        self.init(baseGeometry: primitiveGeometry,
                  bones: bones,
                  boneInverseBindTransforms: ibm,
                  boneWeights: weights,
                  boneIndices: indices)
    }
}
