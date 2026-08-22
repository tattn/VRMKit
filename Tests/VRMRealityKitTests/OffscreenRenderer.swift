#if canImport(RealityKit)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import RealityKit
import UniformTypeIdentifiers
import simd

/// Renders an entity into a Metal texture, so a test can assert on what
/// RealityKit actually draws rather than on the parameters handed to it.
@MainActor
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
enum OffscreenRenderer {
    /// Whether this machine can render at all. A test environment without a
    /// Metal device skips the rendering tests instead of failing them.
    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// Renders `entity` head-on through an orthographic camera framing
    /// x, y in [-1, 1], and returns the pixels as `[row][column]` RGB, row 0 at
    /// the top of the image.
    static func render(_ entity: Entity, size: Int) throws -> [[SIMD3<Float>]] {
        try render(entity, width: size, height: size)
    }

    /// Renders through a perspective camera `distance` in front of the origin.
    /// An orthographic projection shrinks nothing with depth, so it cannot tell
    /// a world-space size from a screen-relative one.
    static func renderPerspective(_ entity: Entity,
                                  size: Int,
                                  distance: Float,
                                  fieldOfViewInDegrees: Float = 60) throws -> [[SIMD3<Float>]] {
        var camera = PerspectiveCameraComponent(near: 0.01,
                                                far: 1000,
                                                fieldOfViewInDegrees: fieldOfViewInDegrees)
        camera.fieldOfViewOrientation = .vertical
        return try render(entity, width: size, height: size, camera: camera, distance: distance)
    }

    /// Renders into a `width` x `height` target. The camera frames y in [-1, 1]
    /// whatever the aspect ratio, so a wider target sees more of x rather than
    /// less of y.
    static func render(_ entity: Entity, width: Int, height: Int) throws -> [[SIMD3<Float>]] {
        // The vertical scale is the half-height of the framed area.
        var camera = OrthographicCameraComponent()
        camera.near = 0.1
        camera.far = 10
        camera.scale = 1
        camera.scaleDirection = .vertical
        return try render(entity, width: width, height: height, camera: camera, distance: 2)
    }

    private static func render(_ entity: Entity,
                               width: Int,
                               height: Int,
                               camera cameraComponent: some Component,
                               distance: Float) throws -> [[SIMD3<Float>]] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.noMetalDevice
        }

        let camera = Entity()
        camera.components.set(cameraComponent)
        camera.position = SIMD3<Float>(0, 0, distance)

        let renderer = try RealityRenderer()
        renderer.entities.append(entity)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.cameraSettings.isToneMappingEnabled = false
        renderer.cameraSettings.antialiasing = .none
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 1))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.noMetalDevice
        }

        let finished = DispatchSemaphore(value: 0)
        try renderer.updateAndRender(deltaTime: 0.01,
                                     cameraOutput: try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target)),
                                     onComplete: { _ in finished.signal() })
        guard finished.wait(timeout: .now() + 30) == .success else {
            throw RenderError.timedOut
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            target.getBytes(base,
                            bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0)
        }
        return (0..<height).map { row in
            (0..<width).map { column in
                let offset = (row * width + column) * 4
                return SIMD3<Float>(Float(bytes[offset]),
                                    Float(bytes[offset + 1]),
                                    Float(bytes[offset + 2]))
            }
        }
    }

    enum RenderError: Error {
        case noMetalDevice
        case timedOut
        case encodingFailed
    }

    /// A `size` x `size` PNG whose texel (row, column) carries a colour unique to
    /// it, so a rendered pixel names the texel it sampled.
    static func makeProbeTexturePNG(size: Int) throws -> Data {
        let step = 256 / size
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let offset = (row * size + column) * 4
                bytes[offset] = UInt8(column * step + step / 2)
                bytes[offset + 1] = UInt8(row * step + step / 2)
                bytes[offset + 2] = 128
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: size,
                                  height: size,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw RenderError.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.encodingFailed
        }
        return data as Data
    }
}
#endif
