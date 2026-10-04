#if canImport(RealityKit)
import Foundation
import ImageIO
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
import simd
@testable import VRMRealityKit

/// The MToon textures the material parameters cannot show: each one is asserted
/// by what it does to the drawn pixels, since a texture bound to a slot RealityKit
/// does not hand to the shader still reads back from the material.
@Suite
@MainActor
struct MToonTextureSlotRenderingTests {
    private static let renderSize = 16

    /// A black rim multiply texture masks the matcap away, as VRMC_materials_mtoon
    /// defines it, leaving the same pixels as no matcap at all.
    @Test
    func testRimMultiplyTextureMasksTheMatcap() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }

        let masked = try await render(matcap: true, rimMultiply: SIMD3(0, 0, 0))
        let unmasked = try await render(matcap: true, rimMultiply: SIMD3(255, 255, 255))
        let bare = try await render(matcap: false, rimMultiply: nil)

        #expect(simd_distance(unmasked, bare) > 0.1, "the matcap draws nothing to mask: \(unmasked) vs \(bare)")
        #expect(simd_distance(masked, bare) < 0.02, "masked \(masked), without a matcap \(bare)")
    }

    /// The rows an app asks for widen the parameter texture without moving the rows
    /// MToon reads, so the material draws the same.
    @Test
    func testMoreUserRowsDrawTheSame() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }

        let standard = try await render(matcap: true, rimMultiply: SIMD3(128, 128, 128))
        let wide = try await render(matcap: true, rimMultiply: SIMD3(128, 128, 128),
                                    shader: MToonShader(userParameterCount: 40))

        #expect(simd_distance(standard, wide) < 0.002, "8 rows \(standard), 40 rows \(wide)")
    }

    /// A MASK material cuts out below its cutoff and draws above it. Only MASK materials
    /// draw with the function that may discard, so this is the one place it shows.
    @Test
    func testMaskMaterialCutsOutBelowTheCutoff() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }

        let below = try await render(matcap: false, rimMultiply: nil, mask: (alpha: 0.3, cutoff: 0.5))
        let above = try await render(matcap: false, rimMultiply: nil, mask: (alpha: 0.7, cutoff: 0.5))

        #expect(below.max() < 0.02, "cut out \(below)")
        #expect(above.x > 0.05, "drawn \(above)")
    }

    /// Separate images for the three single-channel maps share one texture, each
    /// in the channel the map is read from, drawn at the largest image's size.
    @Test
    func testDistinctMapsArePackedIntoTheirChannels() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        func solid(_ value: UInt8, size: Int) throws -> CGImage {
            let png = try OffscreenRenderer.makeTexturePNG(size: size) { _, _ in SIMD3(repeating: value) }
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }

        let packed = try GLTFSceneBuilder.channelPackedImage([try solid(10, size: 2), nil, try solid(200, size: 4)])

        #expect((packed.width, packed.height) == (4, 4))
        let bytes = try #require(packed.dataProvider?.data as Data?)
        #expect(Array(bytes.prefix(3)) == [10, 255, 200])
    }

    /// A black outline width multiply texture leaves no outline, as
    /// VRMC_materials_mtoon defines it, where a white one keeps the full width.
    @Test
    func testOutlineWidthMultiplyTextureNarrowsTheOutline() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }

        let bare = try await cubeWidth(outlineMask: nil)
        let unmasked = try await cubeWidth(outlineMask: SIMD3(255, 255, 255))
        let masked = try await cubeWidth(outlineMask: SIMD3(0, 0, 0))

        #expect(unmasked - bare > 4, "no outline band to mask: \(unmasked)px vs \(bare)px")
        #expect(masked - bare <= 1, "masked outline grew the silhouette by \(masked - bare)px")
    }

    /// The drawn width across the middle row of a cube turned 45° so the
    /// inverted hull widens its silhouette, outlined through `outlineMask`, or
    /// not outlined when it is nil.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func cubeWidth(outlineMask: SIMD3<UInt8>?) async throws -> Int {
        let data = try GLTFSampleAsset.animatedMorphCube.rewritingJSON { json in
            var mtoon: JSONObject = ["specVersion": "1.0"]
            if let outlineMask {
                let png = try OffscreenRenderer.makeTexturePNG(size: 4) { _, _ in outlineMask }
                json["images"] = .objects([["uri": .string("data:image/png;base64,\(png.base64EncodedString())")]])
                json["textures"] = .objects([["source": 0]])
                mtoon["outlineWidthMode"] = "worldCoordinates"
                mtoon["outlineWidthFactor"] = 0.06
                mtoon["outlineColorFactor"] = [1, 0, 0]
                mtoon["outlineWidthMultiplyTexture"] = ["index": 0]
            }
            json["materials"] = .objects([["extensions": ["VRMC_materials_mtoon": .object(mtoon)]]])
            json["extensionsUsed"] = ["VRMC_materials_mtoon"]
        }
        let root = Entity()
        root.addChild(try await GLTFEntityLoader(withData: data, shaders: [MToonShader()]).loadEntity())
        root.scale = SIMD3(repeating: 0.3)
        root.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let image = try OffscreenRenderer.render(root, size: 256)
        return image[image.count / 2].count(where: { $0.max() > 8 })
    }

    /// The middle pixel of a quad filling the viewport.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func render(matcap: Bool, rimMultiply: SIMD3<UInt8>?,
                        mask: (alpha: Float, cutoff: Float)? = nil,
                        shader: MToonShader = MToonShader()) async throws -> SIMD3<Float> {
        let data = try Self.quadGLTF(matcap: matcap, rimMultiply: rimMultiply, mask: mask)
        let entity = try await GLTFEntityLoader(withData: data, shaders: [shader]).loadEntity()
        let image = try OffscreenRenderer.render(entity, size: Self.renderSize)
        return image[Self.renderSize / 2][Self.renderSize / 2] / 255
    }

    /// A quad covering x, y in [-1, 1] with a dark red MToon material, a white
    /// matcap and the given rim multiply texture, all solid colours, cut out by
    /// `mask` when it is given.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func quadGLTF(matcap: Bool, rimMultiply: SIMD3<UInt8>?,
                                 mask: (alpha: Float, cutoff: Float)? = nil) throws -> Data {
        var buffer = Data(littleEndianFloats: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0,
                                               0, 0, 1, 0, 1, 1, 0, 1,
                                               0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1])
        let indexOffset = buffer.count
        buffer.appendLittleEndian([0, 1, 2, 0, 2, 3])

        func image(_ color: SIMD3<UInt8>) throws -> JSONValue {
            let png = try OffscreenRenderer.makeTexturePNG(size: 4) { _, _ in color }
            return ["uri": .string("data:image/png;base64,\(png.base64EncodedString())")]
        }
        var mtoon: JSONObject = [
            "specVersion": "1.0",
            "shadeColorFactor": [0.25, 0, 0],
        ]
        if matcap {
            mtoon["matcapTexture"] = ["index": 1]
            mtoon["matcapFactor"] = [1, 1, 1]
        }
        if rimMultiply != nil {
            mtoon["rimMultiplyTexture"] = ["index": 2]
        }
        var material: JSONObject = [
            "pbrMetallicRoughness": ["baseColorTexture": ["index": 0]],
            "extensions": ["VRMC_materials_mtoon": .object(mtoon)],
        ]
        if let mask {
            material["pbrMetallicRoughness"] = ["baseColorTexture": ["index": 0],
                                                "baseColorFactor": [1, 1, 1, .double(Double(mask.alpha))]]
            material["alphaMode"] = "MASK"
            material["alphaCutoff"] = .double(Double(mask.cutoff))
        }
        let json: JSONObject = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 0, "TEXCOORD_0": 1, "NORMAL": 2],
                "indices": 3,
                "material": 0,
            ]]]],
            "materials": [.object(material)],
            "extensionsUsed": ["VRMC_materials_mtoon"],
            "textures": [["source": 0], ["source": 1], ["source": 2]],
            "images": [try image(SIMD3(64, 0, 0)), try image(SIMD3(255, 255, 255)),
                       try image(rimMultiply ?? SIMD3(255, 255, 255))],
            "buffers": [[
                "uri": .string("data:application/octet-stream;base64,\(buffer.base64EncodedString())"),
                "byteLength": .int(buffer.count),
            ]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 48],
                ["buffer": 0, "byteOffset": 48, "byteLength": 32],
                ["buffer": 0, "byteOffset": 80, "byteLength": 48],
                ["buffer": 0, "byteOffset": .int(indexOffset), "byteLength": 12],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
                 "min": [-1, -1, 0], "max": [1, 1, 0]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
        ]
        return try JSONValue.object(json).serialized()
    }
}
#endif
