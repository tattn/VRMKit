#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import Testing
import VRMKit
@testable import VRMRealityKit

// visionOS has no `CustomMaterial`, so MToon falls back to Unlit there and there is
// no MToon cost to measure.
#if !os(visionOS)

/// Measures what a VRM costs the GPU per frame, at the resolutions a consumer
/// renders at. Not part of a normal test run: set `VRMKIT_BENCH=1` to run it.
///
///     VRMKIT_BENCH=1 swift test -c release --filter MToonRenderBenchmark
///
/// `updateAndRender`'s `onComplete` returns once the frame is encoded, not once
/// the GPU has drawn it, so timing around it measures the CPU alone. The frames
/// here are timed by the shared event `actionsAfterRender` signals, and a few
/// are kept in flight so the GPU stays fed: the wall time of N frames divided by
/// N is then the GPU's frame time.
/// Run this suite on its own, as the command above does: anything running beside a
/// timed loop shows up in its numbers, and suites run in parallel with each other.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VRMKIT_BENCH"] == "1"), .serialized)
@MainActor
struct MToonRenderBenchmark {
    private static let resolutions = [("1080p", 1920, 1080), ("4K", 3840, 2160), ("8K", 7680, 4320)]

    @Test
    func benchmarkSeedSan() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        // A model that fell back to Unlit would benchmark everything but MToon.
        #expect(TestSupport.hasCustomMaterial(in: entity), TestSupport.expectedCustomMaterialMessage)
        entity.isAutomaticUpdateEnabled = false

        for (name, width, height) in Self.resolutions {
            let runs = try (0..<3).map { _ in
                try millisecondsPerFrame(of: entity, width: width, height: height, frames: 120, warmup: 40)
            }
            print(String(format: "BENCH %@: %.3f / %.3f / %.3f ms per frame", name, runs[0], runs[1], runs[2]))
        }
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func millisecondsPerFrame(of entity: Entity,
                                      width: Int,
                                      height: Int,
                                      frames: Int,
                                      warmup: Int) throws -> Double {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Framed head-on from the front, filling the height as a consumer shows it.
        var cameraComponent = PerspectiveCameraComponent(near: 0.01, far: 100, fieldOfViewInDegrees: 30)
        cameraComponent.fieldOfViewOrientation = .vertical
        let camera = Entity()
        camera.components.set(cameraComponent)
        camera.position = SIMD3<Float>(0, 0.9, 2.4)

        let renderer = try RealityRenderer()
        renderer.entities.append(entity)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.cameraSettings.antialiasing = .none

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))
        let drawn = try #require(device.makeSharedEvent())

        var submitted: UInt64 = 0
        func submit() throws {
            submitted += 1
            try renderer.updateAndRender(deltaTime: 1.0 / 60.0,
                                         cameraOutput: output,
                                         actionsAfterRender: [.signal(drawn, value: submitted)])
            // Three frames ahead at most: any further and the queue, not the GPU,
            // would be what the wall clock measures.
            while drawn.signaledValue + 3 < submitted {}
        }

        for _ in 0..<warmup { try submit() }
        while drawn.signaledValue < submitted {}

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<frames { try submit() }
        while drawn.signaledValue < submitted {}
        return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(frames)
    }
}
#endif
#endif
