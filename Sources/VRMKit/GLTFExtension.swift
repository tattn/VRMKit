import Foundation

/// The glTF and VRM extension names this package knows. Reading, merging and
/// writing each decide what may be done with an extension, and spelling the
/// names once keeps the three from disagreeing.
package enum GLTFExtension: String, Sendable, CaseIterable {
    // VRM, at the root of the document.
    case vrm0 = "VRM"
    case vrm1 = "VRMC_vrm"
    case springBone = "VRMC_springBone"
    case vrmAnimation = "VRMC_vrm_animation"
    // VRM, on a node or a material.
    case nodeConstraint = "VRMC_node_constraint"
    case materialsMToon = "VRMC_materials_mtoon"
    // glTF material and texture extensions, which name textures and nothing else.
    case materialsAnisotropy = "KHR_materials_anisotropy"
    case materialsClearcoat = "KHR_materials_clearcoat"
    case materialsDispersion = "KHR_materials_dispersion"
    case materialsEmissiveStrength = "KHR_materials_emissive_strength"
    case materialsIor = "KHR_materials_ior"
    case materialsIridescence = "KHR_materials_iridescence"
    case materialsPBRSpecularGlossiness = "KHR_materials_pbrSpecularGlossiness"
    case materialsSheen = "KHR_materials_sheen"
    case materialsSpecular = "KHR_materials_specular"
    case materialsTransmission = "KHR_materials_transmission"
    case materialsUnlit = "KHR_materials_unlit"
    case materialsVolume = "KHR_materials_volume"
    case meshQuantization = "KHR_mesh_quantization"
    case textureBasisu = "KHR_texture_basisu"
    case textureTransform = "KHR_texture_transform"
    case textureWebP = "EXT_texture_webp"
    // Extensions that hold indices into the document's arrays, which is what
    // keeps them off the mergeable list.
    case animationPointer = "KHR_animation_pointer"
    case audio = "KHR_audio"
    case dracoMeshCompression = "KHR_draco_mesh_compression"
    case lightsPunctual = "KHR_lights_punctual"
    case materialsVariants = "KHR_materials_variants"
    case meshGPUInstancing = "EXT_mesh_gpu_instancing"
    case meshoptCompression = "EXT_meshopt_compression"
}

package extension GLTFExtension {
    /// The extensions a merge can carry over: they hold no indices at all, or
    /// only the `index` of a texture reference, which is rebased with the rest.
    static let mergeable = names(of: [
        .materialsAnisotropy, .materialsClearcoat, .materialsDispersion, .materialsEmissiveStrength,
        .materialsIor, .materialsIridescence, .materialsPBRSpecularGlossiness, .materialsSheen,
        .materialsSpecular, .materialsTransmission, .materialsUnlit, .materialsVolume,
        .meshQuantization, .textureBasisu, .textureTransform, .textureWebP,
        .materialsMToon, .nodeConstraint,
    ])

    /// The VRM extensions at the root of a document, describing the avatar as a
    /// whole, which a merge drops rather than copies.
    static let vrmRoot = names(of: [.vrm0, .vrm1, .springBone, .vrmAnimation])

    /// Every extension this package can say something about. What is not here
    /// may hold references of any shape.
    static let known = names(of: allCases)

    private static func names(of extensions: [GLTFExtension]) -> Set<String> {
        Set(extensions.map(\.rawValue))
    }
}

package extension JSONObject {
    /// Root extensions other than the VRM ones, which merging refuses: their
    /// contents hold references of a shape this cannot know.
    func nonVRMRootExtensions() -> Set<String> {
        Set((object("extensions") ?? [:]).keys).subtracting(GLTFExtension.vrmRoot)
    }

    /// Every extension the document declares, whether it needs it or not.
    func declaredExtensions() -> Set<String> {
        Set(strings("extensionsUsed")).union(strings("extensionsRequired"))
    }

    /// Every extension carried below the root: on a node, a primitive, a buffer
    /// view, a material. glTF has a document declare all of them in
    /// `extensionsUsed`, so reading them off the document itself is what catches
    /// the one that does not, whose contents are no more knowable for that.
    func nestedExtensions() -> Set<String> {
        var names: Set<String> = []
        for (key, value) in self where key != "extensions" {
            collectExtensionNames(in: value, into: &names)
        }
        return names
    }
}

/// `extras` is the document's own data, so a key named `extensions` in there is
/// not one.
private func collectExtensionNames(in value: Any, into names: inout Set<String>) {
    if let object = value as? JSONObject {
        names.formUnion((object.object("extensions") ?? [:]).keys)
        for (key, nested) in object where key != "extras" {
            collectExtensionNames(in: nested, into: &names)
        }
    } else if let array = value as? [Any] {
        for element in array {
            collectExtensionNames(in: element, into: &names)
        }
    }
}
