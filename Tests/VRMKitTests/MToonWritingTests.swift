import Foundation
import Testing
import simd
import VRMTestSupport
@testable import VRMKit

/// MToon is written by inverting the mapping that reads it, so these tests hold that a
/// material model written out and read back is the model it started as.
@Suite
struct MToonWritingTests {
    private let style = MToonConversionStyle(shadeColorScale: 0.7,
                                             shadingToonyFactor: 0.8,
                                             shadingShiftFactor: 0.1,
                                             outlineWidthMode: .worldCoordinates,
                                             outlineWidthFactor: 0.02,
                                             outlineColorFactor: SIMD4<Float>(0.1, 0.2, 0.3, 1))

    // MARK: - Through a document

    /// What the writer saves has to be what the renderer would have shown: both convert
    /// with `StandardMToonConverter`, and nothing may be lost after it.
    @Test
    func testWrittenMToonExtensionReadsBackAsTheConvertedMaterial() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url)

        try document.append(source, under: 0, materials: .mtoon(style))

        let material = try #require(try GLTFDocument(data: try document.serialize())
            .gltf.materials.last)
        let written = try #require(MToonMaterialDescriptor(material: material, materialProperty: nil))
        expectSameShading(written, as: converted(try #require(source.gltf.materials.first)))
    }

    @Test
    func testWrittenVRM0PropertyReadsBackAsTheConvertedMaterial() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(withURL: GLTFSampleAsset.simpleTexture.url)

        try document.append(source, under: 0, materials: .mtoon(style))

        let vrm0 = try VRM0(data: try document.serialize())
        let material = try #require(vrm0.document.gltf.materials.last)
        let written = try #require(MToonMaterialDescriptor(material: material,
                                                           materialProperty: vrm0.materialProperties.last))
        expectSameShading(written, as: converted(try #require(source.gltf.materials.first)))
    }

    /// The fixture material is white and opaque, so the colors, alpha mode and normal
    /// scale only really move when the material has some.
    @Test
    func testAColoredCutoutMaterialReadsBackAsItWasConverted() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: Data(Self.coloredCutoutSource.utf8))

        try document.append(source, under: 0, materials: .mtoon(style))

        let vrm0 = try VRM0(data: try document.serialize())
        let material = try #require(vrm0.document.gltf.materials.last)
        let written = try #require(MToonMaterialDescriptor(material: material,
                                                           materialProperty: vrm0.materialProperties.last))
        expectSameShading(written, as: converted(try #require(source.gltf.materials.first)))
        // The values the fixture cannot show, spelled out.
        #expect(written.alphaMode == .MASK)
        #expect(written.alphaCutoff.isApproximatelyEqual(to: 0.25))
        #expect(written.cullMode == .none)
        #expect(written.normalScale.isApproximatelyEqual(to: 0.5))
        #expect(written.baseColorFactor.isApproximatelyEqual(to: SIMD4<Float>(0.2, 0.4, 0.6, 1)))
    }

    /// A material that already carries MToon keeps what it says: the style describes what
    /// to invent for a material carrying none, not what to overwrite.
    @Test
    func testAppendingWithMToonKeepsAuthoredMToonMaterials() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let source = try GLTFDocument(data: VRMSampleAsset.seedSan.data)
        let authored = source.gltf.materials
        let materialsBefore = try document.typed().materials.count

        try document.append(source, under: 0, materials: .mtoon(style))

        let merged = try GLTFDocument(data: try document.serialize())
        let appended = Array(merged.gltf.materials.dropFirst(materialsBefore))
        #expect(appended.count == authored.count)
        var compared = 0
        for (written, original) in zip(appended, authored) {
            guard let expected = MToonMaterialDescriptor(material: original, materialProperty: nil) else { continue }
            expectSameShading(try #require(MToonMaterialDescriptor(material: written, materialProperty: nil)),
                              as: expected)
            compared += 1
        }
        #expect(compared > 0)
    }

    /// MToon authored in the other format is carried across rather than synthesized, so a
    /// VRM 1.0 material merged into a VRM 0.x avatar keeps its shading in the Unity
    /// property that avatar's runtime reads.
    @Test
    func testAppendingAVRM1MToonSourceIntoAVRM0WritesItsAuthoredShading() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: VRMSampleAsset.seedSan.data)
        let materials = source.gltf.materials
        // A material the style would have shaded differently, so keeping the authored
        // values is what the expectation below can pass on.
        let index = try #require(materials.indices.first { index in
            guard let authored = MToonMaterialDescriptor(material: materials[index],
                                                         materialProperty: nil) else { return false }
            return !authored.shadeColorFactor.isApproximatelyEqual(to: converted(materials[index]).shadeColorFactor)
        })
        let authored = try #require(MToonMaterialDescriptor(material: materials[index], materialProperty: nil))
        let materialsBefore = try document.typed().materials.count

        try document.append(source, under: 0, materials: .mtoon(style))

        let vrm0 = try VRM0(data: try document.serialize())
        let written = VRM0MToonProperty.descriptor(
            property: vrm0.materialProperties[materialsBefore + index],
            material: try #require(vrm0.document.gltf.materials[safe: materialsBefore + index])
        )
        #expect(written.shadeColorFactor.isApproximatelyEqual(to: authored.shadeColorFactor))
    }

    /// A VRM 0.x material property carries one UV transform for every texture of the
    /// material, and one with no textures has none to carry.
    @Test
    func testATextureLessMaterialConvertsIntoAVRM0() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let source = try GLTFDocument(data: Data(Self.textureLessSource.utf8))

        try document.append(source, under: 0, materials: .mtoon(style))

        let vrm0 = try VRM0(data: try document.serialize())
        #expect(vrm0.materialProperties.last?.name == "plain")
        #expect(vrm0.materialProperties.last?.shader == VRM0.MaterialProperty.Shader.mToon.rawValue)
    }

    // MARK: - Through one material model

    /// Every MToon field, including the ones no conversion of a standard material produces.
    @Test
    func testMToonExtensionRoundTripsEveryField() throws {
        let descriptor = Self.richDescriptor
        let material = try Self.material(mtoon: descriptor.mtoonExtension(), of: descriptor)

        let read = try #require(MToonMaterialDescriptor(material: material, materialProperty: nil))

        expectSameShading(read, as: descriptor)
        #expect(read.shadingShiftTextureScale.isApproximatelyEqual(to: descriptor.shadingShiftTextureScale))
        #expect(read.matcapTexture?.index == descriptor.matcapTexture?.index)
        #expect(read.rimMultiplyTexture?.index == descriptor.rimMultiplyTexture?.index)
        #expect(read.uvAnimationMaskTexture?.index == descriptor.uvAnimationMaskTexture?.index)
        #expect(read.outlineWidthMultiplyTexture?.index == descriptor.outlineWidthMultiplyTexture?.index)
        // The UV transform of a texture survives as KHR_texture_transform.
        #expect(read.shadeMultiplyTexture?.transform == descriptor.shadeMultiplyTexture?.transform)
        #expect(read.shadeMultiplyTexture?.texCoord == descriptor.shadeMultiplyTexture?.texCoord)
    }

    /// The same for VRM 0.x, which carries less: one texture transform for the whole
    /// material, no second UV set, and a rim lighting mix its migration pins to 1.
    @Test
    func testVRM0PropertyRoundTripsEveryFieldItCanCarry() throws {
        let descriptor = Self.vrm0RepresentableDescriptor
        let property = try VRM0MToonProperty.materialProperty(from: descriptor, name: "toon")

        let read = VRM0MToonProperty.descriptor(
            property: try property.decode(VRM0.MaterialProperty.self),
            material: try Self.material(mtoon: nil, of: descriptor)
        )

        expectSameShading(read, as: descriptor)
        #expect(read.matcapTexture?.index == descriptor.matcapTexture?.index)
        #expect(read.rimMultiplyTexture?.index == descriptor.rimMultiplyTexture?.index)
        #expect(read.uvAnimationMaskTexture?.index == descriptor.uvAnimationMaskTexture?.index)
        #expect(read.outlineWidthMultiplyTexture?.index == descriptor.outlineWidthMultiplyTexture?.index)
        // VRM 0.x keeps one transform for every texture of the material.
        #expect(read.baseColorTexture?.transform == descriptor.baseColorTexture?.transform)
        #expect(read.shadeMultiplyTexture?.transform == descriptor.baseColorTexture?.transform)
    }

    /// MToon draws a depth-writing transparent material before the rest, and VRM 0.x
    /// carries that ordering as an absolute Unity render queue.
    @Test
    func testTransparentWithZWriteIsWrittenAheadOfPlainTransparent() throws {
        func property(transparentWithZWrite: Bool) throws -> VRM0.MaterialProperty {
            var descriptor = Self.vrm0RepresentableDescriptor
            descriptor.alphaMode = .BLEND
            descriptor.transparentWithZWrite = transparentWithZWrite
            return try VRM0MToonProperty.materialProperty(from: descriptor, name: "toon")
                .decode(VRM0.MaterialProperty.self)
        }

        let zWrite = try property(transparentWithZWrite: true)
        let plain = try property(transparentWithZWrite: false)

        #expect(zWrite.renderQueue == 2501)
        #expect(plain.renderQueue == 3000)
        // Both are `Transparent` to Unity; only the queue separates them.
        #expect(zWrite.tagMap["RenderType"] == "Transparent")
        #expect(plain.tagMap["RenderType"] == "Transparent")
        #expect(zWrite.floatProperties["_BlendMode"] == 3)
        #expect(plain.floatProperties["_BlendMode"] == 2)
    }

    /// A screen-space outline is halved on the way out of VRM 0.x, so the writer doubles
    /// it on the way in.
    @Test
    func testScreenSpaceOutlineWidthSurvivesVRM0() throws {
        let descriptor = Self.vrm0RepresentableDescriptor.with {
            $0.outlineWidthMode = .screenCoordinates
            $0.outlineWidthFactor = 0.015
        }
        let property = try VRM0MToonProperty.materialProperty(from: descriptor, name: nil)

        let read = VRM0MToonProperty.descriptor(
            property: try property.decode(VRM0.MaterialProperty.self),
            material: try Self.material(mtoon: nil, of: descriptor)
        )

        #expect(read.outlineWidthMode == .screenCoordinates)
        #expect(read.outlineWidthFactor.isApproximatelyEqual(to: 0.015))
    }

    // MARK: - Fixtures

    private func converted(_ material: GLTF.Material) -> MToonMaterialDescriptor {
        StandardMToonConverter.convert(material: material, style: style)
    }

    /// A material model using every MToon field, with a distinct value in each so a
    /// writer crossing two of them cannot pass.
    private static let richDescriptor = MToonMaterialDescriptor(
        baseColorFactor: SIMD4<Float>(0.1, 0.2, 0.3, 0.4),
        emissiveFactor: SIMD3<Float>(0.5, 0.6, 0.7),
        shadeColorFactor: SIMD4<Float>(0.11, 0.22, 0.33, 1),
        shadingShiftFactor: 0.12,
        shadingShiftTextureScale: 0.34,
        shadingToonyFactor: 0.56,
        giEqualizationFactor: 0.78,
        matcapFactor: SIMD3<Float>(0.21, 0.32, 0.43),
        parametricRimColorFactor: SIMD4<Float>(0.13, 0.24, 0.35, 1),
        rimLightingMixFactor: 0.46,
        parametricRimFresnelPowerFactor: 3.5,
        parametricRimLiftFactor: 0.57,
        outlineWidthMode: .worldCoordinates,
        outlineWidthFactor: 0.024,
        outlineColorFactor: SIMD4<Float>(0.15, 0.26, 0.37, 1),
        outlineLightingMixFactor: 0.68,
        uvAnimationScrollXSpeedFactor: 0.17,
        uvAnimationScrollYSpeedFactor: -0.28,
        uvAnimationRotationSpeedFactor: 0.39,
        transparentWithZWrite: true,
        renderQueueOffsetNumber: 3,
        alphaMode: .BLEND,
        alphaCutoff: 0.4,
        // glTF says which side is culled with `doubleSided` alone, so front culling is
        // something only VRM 0.x's `_CullMode` can name.
        cullMode: .back,
        normalScale: 0.9,
        baseColorTexture: .init(index: 1),
        emissiveTexture: .init(index: 2),
        shadeMultiplyTexture: .init(index: 3, texCoord: 1,
                                    transform: .init(scale: SIMD2<Float>(2, 3),
                                                     offset: SIMD2<Float>(0.25, 0.5),
                                                     rotation: 0.75)),
        shadingShiftTexture: .init(index: 4),
        normalTexture: .init(index: 5),
        matcapTexture: .init(index: 6),
        rimMultiplyTexture: .init(index: 7),
        outlineWidthMultiplyTexture: .init(index: 8),
        uvAnimationMaskTexture: .init(index: 9)
    )

    /// The same, less what VRM 0.x cannot carry: the rim lighting mix, a render queue
    /// offset, a matcap factor, a shading shift texture, per-texture transforms and a
    /// second UV set. It can say one thing MToon 1.0 cannot: that the front faces are
    /// the culled ones.
    private static let vrm0RepresentableDescriptor = richDescriptor
        .with {
            $0.matcapFactor = SIMD3<Float>(1, 1, 1)
            $0.rimLightingMixFactor = 1
            $0.renderQueueOffsetNumber = 0
            $0.cullMode = .front
            $0.shadingShiftTextureScale = 1
            $0.shadingShiftTexture = nil
        }
        .sharingTextureTransform(.init(scale: SIMD2<Float>(2, 3),
                                       offset: SIMD2<Float>(0.25, 0.5),
                                       rotation: 0))

    /// A glTF material carrying the standard values of `descriptor`, where MToon leaves
    /// them, plus an MToon extension when there is one.
    private static func material(mtoon: JSONObject?, of descriptor: MToonMaterialDescriptor) throws -> GLTF.Material {
        var pbrMetallicRoughness: JSONObject = ["baseColorFactor": .simd(descriptor.baseColorFactor)]
        pbrMetallicRoughness.set("baseColorTexture", descriptor.baseColorTexture?.textureInfo())
        var material: JSONObject = [
            "pbrMetallicRoughness": .object(pbrMetallicRoughness),
            "emissiveFactor": .simd(descriptor.emissiveFactor),
            "alphaMode": .string(descriptor.alphaMode.rawValue),
            "alphaCutoff": .number(descriptor.alphaCutoff),
            "doubleSided": .bool(descriptor.cullMode == .none),
        ]
        material.set("emissiveTexture", descriptor.emissiveTexture?.textureInfo())
        if let normalTexture = descriptor.normalTexture {
            var info = normalTexture.textureInfo()
            info["scale"] = .number(descriptor.normalScale)
            material["normalTexture"] = .object(info)
        }
        material.set("extensions", mtoon.map { [GLTFExtension.materialsMToon.rawValue: JSONValue.object($0)] })
        return try material.decode(GLTF.Material.self)
    }

    /// A material with a color, a cutout and a normal map, and the image it needs.
    private static let textureLessSource = """
    {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "plain", "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0}]}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
        "bufferViews": [{"buffer": 0, "byteLength": 36}],
        "buffers": [{"uri": "data:application/octet-stream;base64,\
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "byteLength": 36}],
        "materials": [{"name": "plain", "pbrMetallicRoughness": {"baseColorFactor": [0.2, 0.4, 0.6, 1]}}]
    }
    """

    private static let coloredCutoutSource = """
    {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "colored", "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "material": 0}]}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}],
        "bufferViews": [{"buffer": 0, "byteLength": 36}],
        "buffers": [{"uri": "data:application/octet-stream;base64,\
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "byteLength": 36}],
        "materials": [{
            "name": "colored",
            "pbrMetallicRoughness": {"baseColorFactor": [0.2, 0.4, 0.6, 1]},
            "emissiveFactor": [0.1, 0.2, 0.3],
            "normalTexture": {"index": 0, "scale": 0.5},
            "alphaMode": "MASK",
            "alphaCutoff": 0.25,
            "doubleSided": true
        }],
        "textures": [{"source": 0}],
        "images": [{"uri": "data:image/png;base64,\
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="}]
    }
    """

    /// Compares every shading value, and which textures the material samples. The indices
    /// move with a merge, so they are only compared where both models came from the same
    /// document.
    private func expectSameShading(_ written: MToonMaterialDescriptor,
                                   as expected: MToonMaterialDescriptor,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        let floatFactors: [(String, KeyPath<MToonMaterialDescriptor, Float>)] = [
            ("shadingShiftFactor", \.shadingShiftFactor),
            ("shadingToonyFactor", \.shadingToonyFactor),
            ("giEqualizationFactor", \.giEqualizationFactor),
            ("rimLightingMixFactor", \.rimLightingMixFactor),
            ("parametricRimFresnelPowerFactor", \.parametricRimFresnelPowerFactor),
            ("parametricRimLiftFactor", \.parametricRimLiftFactor),
            ("outlineWidthFactor", \.outlineWidthFactor),
            ("outlineLightingMixFactor", \.outlineLightingMixFactor),
            ("uvAnimationScrollXSpeedFactor", \.uvAnimationScrollXSpeedFactor),
            ("uvAnimationScrollYSpeedFactor", \.uvAnimationScrollYSpeedFactor),
            ("uvAnimationRotationSpeedFactor", \.uvAnimationRotationSpeedFactor),
            ("alphaCutoff", \.alphaCutoff),
            ("normalScale", \.normalScale),
        ]

        let colorFactors: [(String, KeyPath<MToonMaterialDescriptor, SIMD4<Float>>)] = [
            ("baseColorFactor", \.baseColorFactor),
            ("shadeColorFactor", \.shadeColorFactor),
            ("parametricRimColorFactor", \.parametricRimColorFactor),
            ("outlineColorFactor", \.outlineColorFactor),
        ]

        let textureSlots: [(String, KeyPath<MToonMaterialDescriptor, MToonMaterialDescriptor.Texture?>)] = [
            ("baseColorTexture", \.baseColorTexture),
            ("emissiveTexture", \.emissiveTexture),
            ("shadeMultiplyTexture", \.shadeMultiplyTexture),
            ("normalTexture", \.normalTexture),
            ("matcapTexture", \.matcapTexture),
            ("rimMultiplyTexture", \.rimMultiplyTexture),
            ("outlineWidthMultiplyTexture", \.outlineWidthMultiplyTexture),
            ("uvAnimationMaskTexture", \.uvAnimationMaskTexture),
        ]

        for (name, keyPath) in floatFactors {
            #expect(written[keyPath: keyPath].isApproximatelyEqual(to: expected[keyPath: keyPath]),
                    "\(name)", sourceLocation: sourceLocation)
        }
        for (name, keyPath) in colorFactors {
            #expect(written[keyPath: keyPath].isApproximatelyEqual(to: expected[keyPath: keyPath]),
                    "\(name)", sourceLocation: sourceLocation)
        }
        #expect(written.matcapFactor.isApproximatelyEqual(to: expected.matcapFactor),
                "matcapFactor", sourceLocation: sourceLocation)
        #expect(written.outlineWidthMode == expected.outlineWidthMode,
                "outlineWidthMode", sourceLocation: sourceLocation)
        #expect(written.transparentWithZWrite == expected.transparentWithZWrite,
                "transparentWithZWrite", sourceLocation: sourceLocation)
        #expect(written.renderQueueOffsetNumber == expected.renderQueueOffsetNumber,
                "renderQueueOffsetNumber", sourceLocation: sourceLocation)
        #expect(written.alphaMode == expected.alphaMode, "alphaMode", sourceLocation: sourceLocation)
        #expect(written.cullMode == expected.cullMode, "cullMode", sourceLocation: sourceLocation)

        for (name, keyPath) in textureSlots {
            #expect((written[keyPath: keyPath] != nil) == (expected[keyPath: keyPath] != nil),
                    "\(name)", sourceLocation: sourceLocation)
        }
    }

}

private extension MToonMaterialDescriptor {
    /// The same model with a few values replaced, for describing one fixture in terms
    /// of another.
    func with(_ change: (inout MToonMaterialDescriptor) -> Void) -> MToonMaterialDescriptor {
        var copy = self
        change(&copy)
        return copy
    }

    /// The same model with every texture reading through one shared transform, which is
    /// what a VRM 0.x material can express.
    func sharingTextureTransform(_ transform: UVTransform) -> MToonMaterialDescriptor {
        let textureKeyPaths: [WritableKeyPath<MToonMaterialDescriptor, Texture?>] = [
            \.baseColorTexture, \.emissiveTexture, \.shadeMultiplyTexture, \.shadingShiftTexture, \.normalTexture,
            \.matcapTexture, \.rimMultiplyTexture, \.outlineWidthMultiplyTexture, \.uvAnimationMaskTexture,
        ]
        var copy = self
        for keyPath in textureKeyPaths {
            guard let texture = copy[keyPath: keyPath] else { continue }
            copy[keyPath: keyPath] = .init(index: texture.index, texCoord: 0, transform: transform)
        }
        return copy
    }
}
