import SceneKit
import VRMKitRuntime

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
struct BlendShapeClip {
    let name: String
    let preset: BlendShapePreset
    let values: [BlendShapeBinding]
    //        let materialValues: [MaterialValueBinding] // TODO:
    let isBinary: Bool
    var key: BlendShapeKey {
        return preset == .unknown ? .custom(name) : .preset(preset)
    }
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
struct BlendShapeBinding {
    let mesh: SCNNode
    let index: Int
    let weight: Double
}

@available(*, deprecated, message: "Deprecated. Use VRMRealityKit instead.")
struct MaterialValueBinding {
    let materialName: String
    let valueName: String
    let targetValue: SCNVector4
    let baseValue: SCNVector4
}
