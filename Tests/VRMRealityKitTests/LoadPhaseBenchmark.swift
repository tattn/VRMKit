#if canImport(RealityKit)
import Foundation
import Testing
import VRMKit
@testable import VRMRealityKit
@testable import VRMTestSupport

/// Splits what loading one VRM costs into its phases: parsing the file, the off-actor
/// prepare pass, and the RealityKit resources the build makes on the actor (textures,
/// materials, meshes). Not part of a normal test run: set `VRMKIT_BENCH=1` to run it, and
/// `VRMKIT_BENCH_MODEL` to a `.vrm` path to time a model other than the fixture.
///
///     VRMKIT_BENCH=1 VRMKIT_BENCH_MODEL=/path/to/model.vrm swift test -c release --filter LoadPhaseBenchmark
///
/// Each model is loaded twice: the first load pays the OS shader cache, the second is
/// what a user sees on every later launch.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VRMKIT_BENCH"] == "1"), .serialized)
@MainActor
struct LoadPhaseBenchmark {
    private static var modelURL: URL {
        if let path = ProcessInfo.processInfo.environment["VRMKIT_BENCH_MODEL"] {
            return URL(fileURLWithPath: path)
        }
        return TestAssetBundle.url(forFixture: "VRM/AliciaSolid.vrm")
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    @Test func loadPhases() async throws {
        let url = Self.modelURL
        for iteration in 1...2 {
            let parseStarted = ContinuousClock.now
            let vrm = try await Task.detached { try VRM(withURL: url) }.value
            let parse = ContinuousClock.now - parseStarted

            let loader = VRMEntityLoader(vrm: vrm, shaders: [MToonShader(compensatesToneMapping: false)])
            let root = VRMEntity(vrm: vrm, document: loader.document, sceneIndex: try loader.document.gltf.defaultSceneIndex())
            let builder = GLTFSceneBuilder(resources: loader.resources, root: root)
            try builder.validateDocument()
            let prepareStarted = ContinuousClock.now
            try await builder.prepare()
            let buildStarted = ContinuousClock.now
            _ = try builder.build()
            let build = ContinuousClock.now - buildStarted
            let timings = builder.timings

            print("""
                [LoadPhaseBenchmark] \(url.lastPathComponent) load \(iteration): \
                parse \(parse.milliseconds) ms, \
                prepare \((buildStarted - prepareStarted).milliseconds) ms \
                (geometry \(timings.prepareGeometry.milliseconds) ms, textures \(timings.prepareTextures.milliseconds) ms \
                of which uploads \(timings.textureUploads.milliseconds) ms), \
                build \(build.milliseconds) ms \
                (materials \(timings.materials.milliseconds) ms x\(timings.materialCount), \
                meshes \(timings.meshResources.milliseconds) ms x\(timings.meshResourceCount), \
                late textures \(timings.textureResources.milliseconds) ms x\(timings.textureResourceCount), \
                other \((build - timings.materials - timings.meshResources - timings.textureResources).milliseconds) ms)
                """)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private extension Duration {
    var milliseconds: Int {
        Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
#endif
