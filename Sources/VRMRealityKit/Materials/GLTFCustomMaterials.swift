#if canImport(RealityKit) && !os(visionOS)
import Metal
import RealityKit

/// `CustomMaterial`s initialized once per process and handed out as copies, for a
/// ``GLTFMaterialShader`` that makes its materials per load.
///
/// RealityKit keeps what it builds for every `CustomMaterial` it initializes, through
/// `init(surfaceShader:geometryModifier:lightingModel:)` and `init(from:surfaceShader:geometryModifier:)`
/// alike, for the life of the process, about 200 KB each, while a copy whose blending, culling
/// or depth writes change reuses what it built for that combination. Materials initialized per
/// load pile up with every model loaded; materials copied from these do not.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
public enum GLTFCustomMaterials {
    private struct Key: Hashable {
        let surface: String
        let surfaceLibrary: ObjectIdentifier
        let geometry: String?
        let geometryLibrary: ObjectIdentifier?
        let lightingModel: CustomMaterial.LightingModel
    }

    /// Each material keeps its functions, and so their libraries, alive, which keeps the
    /// library identifiers in the keys from being reused.
    private static var materials: [Key: CustomMaterial] = [:]

    /// A material as `CustomMaterial(surfaceShader:geometryModifier:lightingModel:)` makes it.
    public static func material(surfaceShader: CustomMaterial.SurfaceShader,
                                geometryModifier: CustomMaterial.GeometryModifier? = nil,
                                lightingModel: CustomMaterial.LightingModel) throws -> CustomMaterial {
        let key = Key(surface: surfaceShader.name,
                      surfaceLibrary: ObjectIdentifier(surfaceShader.library),
                      geometry: geometryModifier?.name,
                      geometryLibrary: geometryModifier.map { ObjectIdentifier($0.library) },
                      lightingModel: lightingModel)
        if let material = materials[key] { return material }
        let material = try CustomMaterial(surfaceShader: surfaceShader, geometryModifier: geometryModifier,
                                          lightingModel: lightingModel)
        materials[key] = material
        return material
    }

    /// `source`'s values and textures drawn with other functions, in place of
    /// `CustomMaterial(from:surfaceShader:geometryModifier:)`.
    public static func material(copying source: CustomMaterial,
                                surfaceShader: CustomMaterial.SurfaceShader,
                                geometryModifier: CustomMaterial.GeometryModifier? = nil) throws -> CustomMaterial {
        var material = try material(surfaceShader: surfaceShader, geometryModifier: geometryModifier,
                                    lightingModel: source.lightingModel)
        material.baseColor = source.baseColor
        material.metallic = source.metallic
        material.roughness = source.roughness
        material.emissiveColor = source.emissiveColor
        material.specular = source.specular
        material.normal = source.normal
        material.ambientOcclusion = source.ambientOcclusion
        material.clearcoat = source.clearcoat
        material.clearcoatRoughness = source.clearcoatRoughness
        material.clearcoatNormal = source.clearcoatNormal
        material.custom = source.custom
        material.textureCoordinateTransform = source.textureCoordinateTransform
        material.secondaryTextureCoordinateTransform = source.secondaryTextureCoordinateTransform
        material.opacityThreshold = source.opacityThreshold
        material.blending = source.blending
        material.faceCulling = source.faceCulling
        material.triangleFillMode = source.triangleFillMode
        material.writesDepth = source.writesDepth
        material.readsDepth = source.readsDepth
        return material
    }
}
#endif
