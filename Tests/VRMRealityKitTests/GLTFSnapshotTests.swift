#if canImport(RealityKit)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What a snapshot has to get right: it pictures the model rather than the
/// scene it sits in, from the front whichever version it is, and it leaves the
/// entity it was asked about alone.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct GLTFSnapshotTests {
    private static let size = 128

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static var options: GLTFSnapshotOptions { .init(width: size, height: size) }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func entity(_ asset: VRMSampleAsset) async throws -> VRMEntity {
        try await VRMEntityLoader(withURL: asset.url).loadEntity()
    }

    /// The image as premultiplied RGBA, four bytes a pixel, row 0 at the top.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes,
                                             width: width,
                                             height: height,
                                             bitsPerComponent: 8,
                                             bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    /// Pixels that are not the transparent background, as [row][column].
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func drawnPixels(_ image: CGImage) throws -> [[Bool]] {
        let bytes = try rgbaBytes(image)
        return (0..<image.height).map { row in
            (0..<image.width).map { column in bytes[(row * image.width + column) * 4 + 3] > 8 }
        }
    }

    @Test(arguments: [VRMSampleAsset.aliciaSolid, .vrm1ConstraintTwist])
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotDrawsTheModelWithinTheFrame(asset: VRMSampleAsset) async throws {
        let image = try await entity(asset).snapshot(Self.options)
        #expect(image.width == Self.size && image.height == Self.size)

        let drawn = try drawnPixels(image)
        #expect(drawn.contains { $0.contains(true) })
        // The margin keeps the model off the edges, so nothing is cut off.
        #expect(drawn.first?.allSatisfy { !$0 } == true)
        #expect(drawn.last?.allSatisfy { !$0 } == true)
        #expect(drawn.allSatisfy { !$0[0] && !$0[Self.size - 1] })
    }

    /// The versions face opposite ways, so the snapshot is asserted to match the
    /// view from the model's own front and not the one from behind.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .vrm1ConstraintTwist])
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotLooksAtTheModelFromItsFront(asset: VRMSampleAsset) async throws {
        let entity = try await entity(asset)
        let forward = entity.vrm.forwardDirection
        let front = try drawnPixels(try await entity.snapshot(Self.options))
        var fromForward = Self.options
        fromForward.direction = forward
        var fromBehind = Self.options
        fromBehind.direction = -forward

        #expect(front == (try drawnPixels(try await entity.snapshot(fromForward))))
        #expect(front != (try drawnPixels(try await entity.snapshot(fromBehind))))
    }

    /// The camera is fitted in the model's own space, so where the entity sits
    /// in a scene, and how it is turned or sized there, is not part of it.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotIgnoresTheEntitysOwnTransform() async throws {
        let entity = try await entity(.aliciaSolid)
        let framed = try drawnPixels(try await entity.snapshot(Self.options))

        entity.position = SIMD3(10, -4, 7)
        entity.orientation = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3)))
        entity.scale = SIMD3(repeating: 3)

        #expect(try drawnPixels(try await entity.snapshot(Self.options)) == framed)
    }

    /// A camera looking from the side sees the model's depth as its width, so
    /// the frame has to be fitted along the axes the camera ends up with.
    @Test(arguments: [SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 1), SIMD3<Float>(0, 1, 0.01)])
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotFitsTheModelFromAnyDirection(direction: SIMD3<Float>) async throws {
        var options = Self.options
        options.direction = direction

        let drawn = try drawnPixels(try await entity(.aliciaSolid).snapshot(options))

        #expect(drawn.contains { $0.contains(true) })
        #expect(drawn.first?.allSatisfy { !$0 } == true)
        #expect(drawn.last?.allSatisfy { !$0 } == true)
        #expect(drawn.allSatisfy { !$0[0] && !$0[Self.size - 1] })
    }

    /// The camera is backed off as far as the model needs, so a huge one is
    /// pictured rather than clipped away by a far plane it outgrew.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotDrawsAModelFartherAwayThanADefaultFarPlane() async throws {
        let entity = try await entity(.aliciaSolid)
        // Kilometres tall, which puts the camera several kilometres back.
        entity.children.forEach { $0.scale *= 5000 }

        let drawn = try drawnPixels(try await entity.snapshot(Self.options))

        #expect(drawn.contains { $0.contains(true) })
    }

    /// A frame with no pixels, or a lens with no angle, describes no picture.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotOptionsThatDescribeNoPictureAreRefused() async throws {
        let entity = try await entity(.aliciaSolid)
        let refused = [
            GLTFSnapshotOptions(width: 0, height: 16),
            GLTFSnapshotOptions(width: 16, height: -1),
            // Large enough that the bytes the pixels are read into would
            // overflow the count they are asked for by.
            GLTFSnapshotOptions(width: .max, height: .max),
            GLTFSnapshotOptions(width: 16, height: 16, fieldOfViewInDegrees: 0),
            GLTFSnapshotOptions(width: 16, height: 16, fieldOfViewInDegrees: 180),
            GLTFSnapshotOptions(width: 16, height: 16, fieldOfViewInDegrees: .nan),
            GLTFSnapshotOptions(width: 16, height: 16, direction: SIMD3(.nan, 0, 0)),
            GLTFSnapshotOptions(width: 16, height: 16, margin: 0),
            GLTFSnapshotOptions(width: 16, height: 16, margin: .nan),
            GLTFSnapshotOptions(width: 16, height: 16, lightIntensity: -1),
            GLTFSnapshotOptions(width: 16, height: 16, lightIntensity: .infinity)
        ]
        for options in refused {
            await #expect(throws: GLTFSnapshotError.self) { _ = try await entity.snapshot(options) }
        }
    }

    /// `RealityRenderer` takes an entity out of whatever holds it, so a
    /// snapshot of a model that is on screen has to draw a copy of it.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotLeavesTheEntityInItsScene() async throws {
        let entity = try await entity(.aliciaSolid)
        let parent = Entity()
        parent.addChild(entity)

        _ = try await entity.snapshot(Self.options)

        #expect(parent.children.count == 1)
        #expect(entity.parent === parent)
    }

    /// Only the entity is pictured: a light or a floor standing beside it in
    /// the scene is not part of the model's portrait.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotDrawsNeitherSiblingsNorTheBackgroundByDefault() async throws {
        let entity = try await entity(.aliciaSolid)
        let parent = Entity()
        parent.addChild(entity)
        let floor = ModelEntity(mesh: .generateBox(width: 10, height: 0.1, depth: 10),
                                materials: [UnlitMaterial(color: .red)])
        parent.addChild(floor)

        let drawn = try drawnPixels(try await entity.snapshot(Self.options))
        // A floor that wide would fill the frame's lower rows if it were drawn.
        #expect(drawn[Self.size - 2].allSatisfy { !$0 })
    }

    /// RealityKit hands its render target the values it drew rather than the
    /// encoded ones, so a linear target reads back far darker than what was drawn.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotDrawsAColorAtTheBrightnessItWasGiven() async throws {
        let entity = GLTFEntity()
        let gray: CGFloat = 0.5
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .init(red: gray, green: gray, blue: gray, alpha: 1))
        entity.addChild(ModelEntity(mesh: .generateBox(size: 1), materials: [material]))

        let bytes = try rgbaBytes(try await entity.snapshot(Self.options))

        let center = ((Self.size / 2) * Self.size + Self.size / 2) * 4
        let expected = Double(gray) * 255
        #expect(abs(Double(bytes[center]) - expected) <= 4,
                "a face painted \(expected) came back at \(bytes[center])")
    }

    /// The mean brightness of what was drawn, ignoring the background.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func brightness(_ image: CGImage) throws -> Double {
        let bytes = try rgbaBytes(image)
        var total = 0.0
        var count = 0.0
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 8 {
            total += (Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])) / 3
            count += 1
        }
        return count > 0 ? total / count : 0
    }

    /// MToon shades from a light the materials carry, and a copy carries the
    /// values but none of the runtime that sets them, so aiming that light at
    /// the copy after making it would do nothing at all.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func mtoonIsLitFromTheCameraRatherThanFromWhereTheEntityPoints() async throws {
        // A model whose shade color differs from its base color, so that where
        // the light comes from is something the pixels can show.
        let entity = try await entity(.vrm1ConstraintTwist)
        // Photographed from behind, where the entity's own light does not reach.
        var lit = Self.options
        lit.direction = -entity.vrm.forwardDirection
        var unlit = lit
        unlit.mtoonLitFromCamera = false

        #expect(try brightness(try await entity.snapshot(lit)) > (try brightness(try await entity.snapshot(unlit))))
    }

    /// Lighting the copy is done by aiming the entity's own light and putting
    /// it back, which the caller must not be able to tell happened.
    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotLeavesTheEntitysOwnLightWhereItWas() async throws {
        let entity = try await entity(.aliciaSolid)
        let direction = SIMD3<Float>(1, 0, 0)
        entity.setMToonLightDirection(direction)

        _ = try await entity.snapshot(Self.options)

        #expect(entity.mtoonLightDirection == direction)
    }

    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotPNGDataDecodesBackToTheRenderedImage() async throws {
        let data = try await entity(.aliciaSolid).snapshotPNGData(Self.options)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == Self.size && image.height == Self.size)
    }

    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func snapshotOfAnEmptyEntityIsRefused() async throws {
        let entity = try await GLTFEntityLoader(withURL: GLTFSampleAsset.triangle.url).loadEntity()
        entity.children.forEach { $0.removeFromParent() }
        await #expect(throws: GLTFSnapshotError.self) {
            _ = try await entity.snapshot(Self.options)
        }
    }
}
#endif
