#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import simd
@testable import VRMRealityKit

/// Renders `KHR_texture_transform` through the loader and checks which texels end
/// up on screen.
///
/// Reading the converted parameters back proves nothing: the conversion mirrors
/// the rotation because the loader also flips V, and only the drawn result says
/// whether the two cancel out. Every expectation here comes from the extension's
/// own `translation * rotation * scale` applied to the glTF UV.
@Suite
@MainActor
struct TextureTransformRenderingTests {
    /// The probe texture is 8x8 and each texel is rendered 8 pixels wide.
    private static let textureSize = 8
    private static let renderSize = 64

    /// One `KHR_texture_transform`, with the matrix the extension defines.
    private struct UVTransform {
        var offset: SIMD2<Float> = .zero
        var scale: SIMD2<Float> = .one
        var rotation: Float = 0

        var json: JSONValue {
            ["offset": .numbers([offset.x, offset.y]),
             "scale": .numbers([scale.x, scale.y]),
             "rotation": .number(rotation)]
        }

        /// `translation * rotation * scale` applied to a glTF UV.
        func applied(to uv: SIMD2<Float>) -> SIMD2<Float> {
            let cosine = cos(rotation), sine = sin(rotation)
            return SIMD2<Float>(scale.x * cosine * uv.x + scale.y * sine * uv.y + offset.x,
                                -scale.x * sine * uv.x + scale.y * cosine * uv.y + offset.y)
        }
    }

    @Test
    func testTransformedUVsSampleTheTexelsTheExtensionNames() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        // Nothing to assert on a machine that cannot render.
        guard OffscreenRenderer.isAvailable else { return }

        // With no transform a rendered pixel shows the texel its own UV names,
        // which both checks the V flip and calibrates colour → texel below.
        let identity = try await render(UVTransform())
        var texelOfColour: [SIMD3<Float>: SIMD2<Int>] = [:]
        let pixelsPerTexel = Self.renderSize / Self.textureSize
        for row in 0..<Self.textureSize {
            for column in 0..<Self.textureSize {
                let pixel = identity[row * pixelsPerTexel + pixelsPerTexel / 2][column * pixelsPerTexel + pixelsPerTexel / 2]
                texelOfColour[pixel] = SIMD2<Int>(column, row)
            }
        }
        // The identity render doubles as the machine's capability check: the
        // visionOS simulator hands back a blank frame wherever RealityKit's
        // pipelines fail to compile.
        let rendersEveryTexel = texelOfColour.count == Self.textureSize * Self.textureSize
#if os(visionOS)
        guard rendersEveryTexel else { return }

        /// Whether a frame carries the probe at all. A pipeline that failed to compile
        /// leaves the background, which is none of the probe's colours.
        func showsTheProbe(_ rendered: [[SIMD3<Float>]]) -> Bool {
            rendered.contains { row in row.contains { texelOfColour[$0] != nil } }
        }
#endif
        #expect(rendersEveryTexel, "the identity render must show every texel exactly once")

        let transforms: [(name: String, transform: UVTransform)] = [
            ("offset", UVTransform(offset: SIMD2<Float>(0.25, 0.5))),
            ("scale", UVTransform(scale: SIMD2<Float>(2, 0.5))),
            ("rotation", UVTransform(rotation: .pi / 2)),
            ("offset and scale", UVTransform(offset: SIMD2<Float>(0.125, -0.375),
                                                                                                     scale: SIMD2<Float>(0.5, 2))),
            ("all", UVTransform(offset: SIMD2<Float>(-0.2, -0.1),
                                                                                        scale: SIMD2<Float>(1.5, 1.5),
                                                                                        rotation: 0.3)),
        ]

        for (name, transform) in transforms {
            let rendered = try await render(transform)
#if os(visionOS)
            // One frame compiling is no promise for the next: the simulator fails a
            // pipeline now and then, and only some of this test's frames come back.
            guard showsTheProbe(rendered) else { continue }
#endif
            var checked = 0
            for row in stride(from: 2, to: Self.renderSize, by: 5) {
                for column in stride(from: 2, to: Self.renderSize, by: 5) {
                    let uv = SIMD2<Float>((Float(column) + 0.5) / Float(Self.renderSize),
                                          (Float(row) + 0.5) / Float(Self.renderSize))
                    let texel = transform.applied(to: uv) * Float(Self.textureSize)
                    // A sample landing near a texel edge is one rounding apart
                    // from either neighbour, so it proves nothing.
                    guard texel.x.truncatingRemainder(dividingBy: 1).magnitude > 0.2,
                          texel.y.truncatingRemainder(dividingBy: 1).magnitude > 0.2,
                          (1 - texel.x.truncatingRemainder(dividingBy: 1).magnitude) > 0.2,
                          (1 - texel.y.truncatingRemainder(dividingBy: 1).magnitude) > 0.2 else { continue }
                    checked += 1
                    let expected = SIMD2<Int>(wrapped(texel.x), wrapped(texel.y))
                    #expect(texelOfColour[rendered[row][column]] == expected,
                            "\(name): pixel (\(row), \(column)) must sample texel \(expected)")
                }
            }
            #expect(checked > 20, "\(name): too few usable samples")
        }
    }

    /// The texel index a transformed UV names, with the sampler's repeat wrap.
    private func wrapped(_ scaledUV: Float) -> Int {
        let index = Int(scaledUV.rounded(.down)) % Self.textureSize
        return index < 0 ? index + Self.textureSize : index
    }

    /// Loads a one-quad glTF whose only material carries `transform`, and renders
    /// it filling the viewport.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func render(_ transform: UVTransform) async throws -> [[SIMD3<Float>]] {
        let entity = try await GLTFEntityLoader(withData: Self.quadGLTF(transform)).loadEntity()
        return try OffscreenRenderer.render(entity, size: Self.renderSize)
    }

    /// A glTF of a single unlit quad covering x, y in [-1, 1], textured with the
    /// probe image through `transform`. Both resources are data URIs, so the
    /// document needs no directory of its own.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func quadGLTF(_ transform: UVTransform) throws -> Data {
        var buffer = Data()
        // POSITION, then TEXCOORD_0 in glTF's V-down convention, then indices.
        for position in [SIMD3<Float>(-1, -1, 0), .init(1, -1, 0), .init(1, 1, 0), .init(-1, 1, 0)] {
            for component in [position.x, position.y, position.z] {
                withUnsafeBytes(of: component.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
            }
        }
        for uv in [SIMD2<Float>(0, 1), .init(1, 1), .init(1, 0), .init(0, 0)] {
            for component in [uv.x, uv.y] {
                withUnsafeBytes(of: component.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
            }
        }
        let indexOffset = buffer.count
        for index in [0, 1, 2, 0, 2, 3] as [UInt16] {
            withUnsafeBytes(of: index.littleEndian) { buffer.append(contentsOf: $0) }
        }

        let png = try OffscreenRenderer.makeProbeTexturePNG(size: textureSize)
        let json: JSONObject = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 0, "TEXCOORD_0": 1],
                "indices": 2,
                "material": 0,
            ]]]],
            "materials": [[
                "pbrMetallicRoughness": [
                    "baseColorTexture": [
                        "index": 0,
                        "extensions": ["KHR_texture_transform": transform.json],
                    ],
                ],
                // Unlit keeps the rendered colour equal to the sampled texel.
                "extensions": ["KHR_materials_unlit": [:]],
            ]],
            "extensionsUsed": ["KHR_materials_unlit", "KHR_texture_transform"],
            "textures": [["sampler": 0, "source": 0]],
            // Nearest filtering and repeat wrapping keep every rendered pixel one
            // whole texel of the probe image.
            "samplers": [["magFilter": 9728, "minFilter": 9728, "wrapS": 10497, "wrapT": 10497]],
            "images": [["uri": .string("data:image/png;base64,\(png.base64EncodedString())")]],
            "buffers": [[
                "uri": .string("data:application/octet-stream;base64,\(buffer.base64EncodedString())"),
                "byteLength": .int(buffer.count),
            ]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 48],
                ["buffer": 0, "byteOffset": 48, "byteLength": 32],
                ["buffer": 0, "byteOffset": .int(indexOffset), "byteLength": 12],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
                           "min": [-1, -1, 0], "max": [1, 1, 0]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 2, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
        ]
        return try JSONValue.object(json).serialized()
    }
}
#endif
