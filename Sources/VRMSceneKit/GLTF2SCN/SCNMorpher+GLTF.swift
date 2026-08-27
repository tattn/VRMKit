import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNMorpher {
    /// `corners` unshares each target's vectors the way the primitive's own were
    /// unshared, for one flat shaded because it ships no NORMAL.
    convenience init(primitiveTargets: [[GLTF.Mesh.Primitive.AttributeKey: Int]],
                     loader: VRMSceneLoader,
                     corners: [Int]? = nil) throws {
        self.init()
        for target in primitiveTargets {
            var sources = try loader.attributes(target)
            if let corners {
                sources = try sources.map { try $0.expanded(to: corners) }
            }
            let geometry = SCNGeometry(sources: sources, elements: nil)
            targets.append(geometry)
        }
        calculationMode = .additive
    }
}
