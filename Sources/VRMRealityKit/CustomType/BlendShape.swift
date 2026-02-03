#if canImport(RealityKit)
import RealityKit
import VRMKitRuntime

struct BlendShapeClip {
    let name: String
    let preset: BlendShapePreset
    let values: [BlendShapeBinding]
    let isBinary: Bool
    var key: BlendShapeKey {
        return preset == .unknown ? .custom(name) : .preset(preset)
    }
}

struct BlendShapeBinding {
    let mesh: Entity
    let index: Int
    let weight: Double
}

struct MaterialValueBinding {
    let materialName: String
    let valueName: String
    let targetValue: SIMD4<Float>
    let baseValue: SIMD4<Float>
}
#endif
