import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

@Suite
struct GLTFMToonTests {
    /// VRM 0.x keeps MToon in the Unity material property, so a converted material
    /// replaces the entry saying "render the glTF material as it is".
    @Test
    func testAppendingAsMToonWritesAVRM0MaterialProperty() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url)
        let textureBase = try document.typed().textures.count

        try document.append(source, under: 0, materials: .mtoon)

        let json = try GLTFDocument(data: try document.serialize()).rawJSON()
        let properties = try #require(json.object("extensions")?.object("VRM")).objects("materialProperties")
        #expect(properties.count == json.objects("materials").count)

        let property = try #require(properties.last)
        #expect(property.string("shader") == "VRM/MToon")
        #expect(property.object("tagMap")?.string("RenderType") == "Opaque")
        let textures = try #require(property.object("textureProperties"))
        #expect(textures.int("_MainTex") == textureBase)
        #expect(textures.int("_ShadeTexture") == textureBase)
        // The fixture's material is white, so the shade color is the scale itself,
        // written back in the sRGB space VRM 0.x keeps colors in.
        let shadeColor = try #require(property.object("vectorProperties")?.floats("_ShadeColor"))
        #expect(shadeColor[0].isApproximatelyEqual(to: SRGB.fromLinear(0.8)))
        #expect(shadeColor[3] == 1)
        let floats = try #require(property.object("floatProperties"))
        #expect(floats.float("_IndirectLightIntensity")?.isApproximatelyEqual(to: 0.1) == true)
        #expect(floats.float("_RimFresnelPower") == 5)
    }

    /// Everywhere else MToon is the glTF extension, next to the unlit fallback it names
    /// for clients that do not implement it.
    @Test
    func testAppendingAsMToonWritesTheMToonExtension() throws {
        let vrm = try VRM(data: VRMSampleAsset.seedSan.data)
        var document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let head = GLTFNodeIndex(try #require(vrm.nodeIndex(of: .head)))
        let textureBase = try document.typed().textures.count

        try document.append(try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url),
                            under: head,
                            materials: .mtoon)

        let reloaded = try GLTFDocument(data: try document.serialize())
        let material = try #require(reloaded.gltf.materials.last)
        let mtoon = try #require(material.extensions?.materialsMToon)
        #expect(mtoon.specVersion == "1.0")
        #expect(try #require(mtoon.shadeColorFactor).allSatisfy { $0.isApproximatelyEqual(to: 0.8) })
        #expect(mtoon.shadeColorFactor?.count == 3)
        #expect(mtoon.shadeMultiplyTexture?.index == textureBase)
        #expect(mtoon.shadingToonyFactor?.isApproximatelyEqual(to: 0.9) == true)
        #expect(mtoon.outlineWidthMode == MToonOutlineWidthMode.none)
        #expect(material.extensions?.materialsUnlit != nil)
        let used = reloaded.gltf.extensionsUsed
        #expect(used.contains("VRMC_materials_mtoon"))
        #expect(used.contains("KHR_materials_unlit"))
        // The VRM 1.0 model has no parallel array to keep in step.
        #expect(try reloaded.rawJSON().object("extensions")?.object("VRM") == nil)
    }

    /// An outline is the one part of the style with a unit to get wrong: MToon 1.0
    /// measures world-space width in meters and VRM 0.x in centimeters.
    @Test
    func testOutlineWidthIsWrittenInEachFormsOwnUnit() throws {
        let style = MToonConversionStyle(outlineWidthMode: .worldCoordinates, outlineWidthFactor: 0.02)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url)

        var vrm0 = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        try vrm0.append(source, under: 0, materials: .mtoon(style))
        let property = try #require(try GLTFDocument(data: try vrm0.serialize()).rawJSON()
            .object("extensions")?.object("VRM")?.objects("materialProperties").last)
        let floats = try #require(property.object("floatProperties"))
        #expect(floats.float("_OutlineWidthMode") == 1)
        #expect(floats.float("_OutlineWidth")?.isApproximatelyEqual(to: 2) == true)

        var vrm1 = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        try vrm1.append(source, under: 0, materials: .mtoon(style))
        let mtoon = try #require(try GLTFDocument(data: try vrm1.serialize())
            .gltf.materials.last?.extensions?.materialsMToon)
        #expect(mtoon.outlineWidthMode == .worldCoordinates)
        #expect(mtoon.outlineWidthFactor?.isApproximatelyEqual(to: 0.02) == true)
    }

    @Test
    func testConvertingTheMaterialsOfAPlainGLTF() throws {
        var document = try GLTFEditableDocument(data: GLTFSampleAsset.simpleTexture.data,
                                                rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory)

        try document.convertMaterialsToMToon(at: [0])

        let reloaded = try GLTFDocument(data: try document.serialize())
        #expect(reloaded.gltf.materials[0].extensions?.materialsMToon != nil)
        #expect(reloaded.gltf.extensionsUsed.contains("VRMC_materials_mtoon") == true)
    }

    /// VRM 0.x applies one UV transform to every texture of a material and samples UV
    /// set 0 only, so a rotation or a second UV set cannot be written faithfully.
    @Test(arguments: ["rotation", "texCoord"])
    func testConvertingToVRM0RefusesUVStateItCannotCarry(unsupported: String) throws {
        let source = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            var materials = json.objects("materials")
            materials[0].withObject("pbrMetallicRoughness") { pbr in
                pbr.withObject("baseColorTexture") {
                    $0["extensions"] = ["KHR_texture_transform": [unsupported: 1]]
                }
            }
            json["materials"] = .objects(materials)
            json["extensionsUsed"] = ["KHR_texture_transform"]
        }
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.serialize()

        #expect(throws: VRMError.self) {
            try document.append(try GLTFDocument(data: source,
                                                 rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory),
                                under: 0,
                                materials: .mtoon)
        }
        #expect(try document.serialize() == before)
    }

    /// A transform every texture shares is what VRM 0.x does carry, as the material's
    /// `_MainTex` scale and offset.
    @Test
    func testConvertingToVRM0KeepsATransformEveryTextureShares() throws {
        let source = try GLTFSampleAsset.simpleTexture.rewritingJSON { json in
            var materials = json.objects("materials")
            materials[0].withObject("pbrMetallicRoughness") { pbr in
                pbr.withObject("baseColorTexture") {
                    $0["extensions"] = ["KHR_texture_transform": ["scale": [2, 4], "offset": [0.25, 0.5]]]
                }
            }
            json["materials"] = .objects(materials)
            json["extensionsUsed"] = ["KHR_texture_transform"]
        }
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)

        try document.append(try GLTFDocument(data: source,
                                             rootDirectory: GLTFSampleAsset.simpleTexture.rootDirectory),
                            under: 0,
                            materials: .mtoon)

        let property = try #require(try GLTFDocument(data: try document.serialize()).rawJSON()
            .object("extensions")?.object("VRM")?.objects("materialProperties").last)
        let mainTex = try #require(property.object("vectorProperties")?.floats("_MainTex"))
        // Unity keeps offset, scale in a bottom-left UV origin.
        #expect(mainTex == [0.25, 1 - 0.5 - 4, 2, 4])
    }

    @Test
    func testConvertingAMaterialThatIsNotThereThrows() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)

        #expect(throws: VRMError.self) { try document.convertMaterialsToMToon(at: [100_000]) }
    }

    /// Keeping the materials is still the default, and still writes the entry telling a
    /// VRM 0.x runtime to use the glTF material.
    @Test
    func testKeepingTheMaterialsWritesTheGLTFShaderProperty() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)

        try document.append(try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url), under: 0)

        let merged = try VRM0(data: try document.serialize())
        #expect(merged.materialProperties.last?.shader == "VRM_USE_GLTFSHADER")
    }

    /// `materialProperties` runs parallel to `materials`, and glTF lets two materials
    /// share a name, so only the index tells them apart.
    @Test
    func testMaterialSettingsAreResolvedByIndexNotByName() throws {
        let duplicated = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            json.mapObjects(.materials) { material in
                var material = material
                material["name"] = "same"
                return material
            }
            json.withObject("extensions") { extensions in
                extensions.withObject(GLTFExtension.vrm0.rawValue) { vrm in
                    vrm.mapObjects("materialProperties") { property in
                        var property = property
                        property["name"] = "same"
                        return property
                    }
                }
            }
        }
        let vrm0 = try VRM0(data: duplicated)
        let materials = vrm0.document.gltf.materials
        #expect(materials.count > 1)

        // The materials differ in shader despite sharing a name, so a name-keyed lookup
        // could only answer with one of them.
        let shaders = Set(vrm0.materialProperties.map(\.shader))
        #expect(shaders.count > 1)

        for index in materials.indices {
            let property = try #require(vrm0.materialProperty(at: index))
            #expect(property.shader == vrm0.materialProperties[index].shader, "material \(index)")
        }
        #expect(vrm0.materialProperty(at: materials.count) == nil)
    }
}
