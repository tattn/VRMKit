import Foundation

/// How ``GLTFEditableDocument/append(_:under:name:transform:materials:)`` writes
/// the materials it copies over.
public enum GLTFMaterialConversion: Equatable, Sendable {
    /// Copies them as they are, which for a VRM 0.x document means the material
    /// property telling its runtime to render the glTF material unchanged.
    case keep
    /// Writes them as MToon, so an item merged into a toon-shaded model is
    /// shaded like the model rather than like a PBR prop.
    case mtoon(MToonConversionStyle)

    /// Converts with the default ``MToonConversionStyle``.
    public static var mtoon: GLTFMaterialConversion { .mtoon(.init()) }
}

extension GLTFEditableDocument {
    /// Makes the materials at `indices` MToon, leaving the ones that already
    /// are as they were authored.
    ///
    /// A material carrying no MToon data is converted from the standard Unlit /
    /// PBR values it has, through `StandardMToonConverter`, which is also what a
    /// renderer toon-shades a plain material with, so a preview and a save look
    /// alike. One that carries MToon data keeps it: `style` describes what to
    /// invent where there is nothing, not what to overwrite.
    ///
    /// The form follows the document: a VRM 0.x model gets the Unity material
    /// property its runtime reads, and every other document gets the
    /// `VRMC_materials_mtoon` extension with a `KHR_materials_unlit` fallback.
    /// A material already MToon in the other form is carried across into this
    /// one, so a VRM 1.0 material merged into a VRM 0.x avatar keeps its shading.
    public func convertMaterialsToMToon(at indices: some Sequence<Int>,
                                        style: MToonConversionStyle = .init()) throws {
        // Only the materials are decoded, not the whole document.
        let materialObjects = json.objects(.materials)
        let vrm0Properties = vrm0MaterialProperties()
        var converted: [ConvertedMaterial] = []
        for index in indices {
            guard materialObjects.indices.contains(index) else {
                throw VRMError._dataInconsistent(
                    "material index \(index) is out of range for the \(materialObjects.count) materials of the document"
                )
            }
            let material = try materialObjects[index].decode(GLTF.Material.self)
            // Decoded rather than read past: a property this cannot make sense
            // of is one whose material would be rewritten from invented values,
            // which is what the unsupported MToon version below refuses too.
            let vrm0Property = try vrm0Properties?[safe: index]
                .map { try $0.decode(VRM0.MaterialProperty.self) }
            // Already written in the form this document keeps MToon in, so
            // there is nothing to write that it does not already say.
            let isAuthoredHere = vrm0Properties == nil
                ? material.extensions?.materialsMToon != nil
                : vrm0Property?.vrmShader == .mToon
            guard !isAuthoredHere else { continue }

            switch MToonMaterialDescriptor.resolve(material: material, materialProperty: vrm0Property) {
            case .supported(let authored):
                converted.append((index, material.name, authored))
            case .unsupportedVersion(let specVersion):
                throw VRMError._notSupported(
                    "material \(index) is MToon at specVersion \(specVersion), which this package does not read, "
                    + "so rewriting it would replace what it says with invented values"
                )
            case .none:
                converted.append((index, material.name, StandardMToonConverter.convert(material: material,
                                                                                       vrm0Property: vrm0Property,
                                                                                       style: style)))
            }
        }

        guard var properties = vrm0Properties else {
            writeMToonExtensions(converted)
            return
        }
        for (index, name, descriptor) in converted {
            guard properties.indices.contains(index) else {
                throw VRMError._dataInconsistent(
                    "the VRM materialProperties hold \(properties.count) entries, so material \(index) has none"
                )
            }
            properties[index] = try VRM0MToonProperty.materialProperty(from: descriptor, name: name)
        }
        setVRM0MaterialProperties(properties)
    }

    private func writeMToonExtensions(_ converted: [ConvertedMaterial]) {
        guard !converted.isEmpty else { return }
        var materials = json.objects(.materials)
        for (index, _, descriptor) in converted {
            var extensions = materials[index].object("extensions") ?? [:]
            extensions[GLTFExtension.materialsMToon.rawValue] = descriptor.mtoonExtension()
            extensions[GLTFExtension.materialsUnlit.rawValue] = JSONObject()
            materials[index]["extensions"] = extensions
        }
        json[.materials] = materials

        var used: Set<String> = [GLTFExtension.materialsMToon.rawValue, GLTFExtension.materialsUnlit.rawValue]
        if converted.contains(where: { $0.descriptor.textures.contains(where: \.needsTextureTransform) }) {
            used.insert(GLTFExtension.textureTransform.rawValue)
        }
        declareExtensions(used: used)
    }

    /// The VRM 0.x material properties, which run parallel to `materials`, or
    /// nil for a document that is not a VRM 0.x model.
    func vrm0MaterialProperties() -> [JSONObject]? {
        guard let vrm = json.object("extensions")?.object(GLTFExtension.vrm0.rawValue),
              vrm["materialProperties"] != nil else { return nil }
        return vrm.objects("materialProperties")
    }

    /// VRM 0.x keeps its material settings in an array parallel to `materials`,
    /// so materials added to such a document need an entry each to keep the two
    /// lined up. `VRM_USE_GLTFSHADER` says the glTF material describes itself,
    /// which is what one just written or copied in does.
    func appendVRM0MaterialProperties(named names: [String?]) {
        guard !names.isEmpty, let properties = vrm0MaterialProperties() else { return }
        setVRM0MaterialProperties(properties + names.map(VRM0MToonProperty.gltfShaderProperty(name:)))
    }

    func setVRM0MaterialProperties(_ properties: [JSONObject]) {
        json.withObject("extensions") { extensions in
            extensions.withObject(GLTFExtension.vrm0.rawValue) { vrm in
                vrm["materialProperties"] = properties
            }
        }
    }
}

/// A material as the conversion leaves it, with where it goes back.
private typealias ConvertedMaterial = (index: Int, name: String?, descriptor: MToonMaterialDescriptor)
