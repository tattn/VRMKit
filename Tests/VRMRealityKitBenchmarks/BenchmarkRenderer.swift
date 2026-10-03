#if canImport(RealityKit)
import Metal
import RealityKit
import Testing

/// A `RealityRenderer` drawing `entity` the way a consumer shows a model: framed
/// head-on from the front, filling the height.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
struct BenchmarkRenderer {
    let device: any MTLDevice
    let renderer: RealityRenderer

    init(rendering entity: Entity) throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        var cameraComponent = PerspectiveCameraComponent(near: 0.01, far: 100, fieldOfViewInDegrees: 30)
        cameraComponent.fieldOfViewOrientation = .vertical
        let camera = Entity()
        camera.components.set(cameraComponent)
        camera.position = SIMD3<Float>(0, 0.9, 2.4)

        renderer = try RealityRenderer()
        renderer.entities.append(entity)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
    }

    /// A GPU-only RGBA target of `width` x `height` pixels to draw into.
    func output(width: Int, height: Int) throws -> RealityRenderer.CameraOutput {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        return try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))
    }
}
#endif
