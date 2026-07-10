import VRMKit
import SceneKit

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
extension SCNMorpher {
    convenience init(primitiveTargets: [[GLTF.Mesh.Primitive.AttributeKey: Int]], loader: VRMSceneLoader) throws {
        self.init()
        for target in primitiveTargets {
            let sources = try loader.attributes(target)
            let geometry = SCNGeometry(sources: sources, elements: nil)
            targets.append(geometry)
        }
        calculationMode = .additive
    }
}
