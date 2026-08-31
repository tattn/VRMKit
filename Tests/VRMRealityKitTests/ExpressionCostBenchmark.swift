#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMKitRuntime
@testable import VRMRealityKit

/// What driving expressions costs per frame, for an app that hands the model a
/// full set of weights every frame (face tracking).
/// Not part of a normal test run: set `VRMKIT_BENCH=1` to run it.
///
///     VRMKIT_BENCH=1 swift test -c release --filter ExpressionCostBenchmark
///
/// Run this suite on its own: suites run in parallel with each other, and anything
/// running beside a timed loop shows up in its numbers. `VRMKIT_BENCH_FRAMES`
/// lengthens the loop, for attaching a profiler to it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VRMKIT_BENCH"] == "1"), .serialized)
@MainActor
struct ExpressionCostBenchmark {
    /// The ARKit blend shape names a Perfect Sync rig is driven by. A model that
    /// does not carry them still pays for looking each one up.
    private static let perfectSyncNames = [
        "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
        "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight",
        "eyeLookDownLeft", "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight",
        "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight",
        "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight", "jawForward",
        "jawLeft", "jawOpen", "jawRight", "mouthClose", "mouthDimpleLeft", "mouthDimpleRight",
        "mouthFrownLeft", "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft",
        "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight",
        "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
        "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight",
        "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft", "noseSneerRight", "tongueOut",
    ]

    @Test
    func inspectExpressions() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let available = entity.availableExpressions
        print("BENCH seedSan expressions: \(available.count)")
        print("BENCH   presets: \(available.filter(\.key.isPreset).count)"
              + "  custom: \(available.filter { !$0.key.isPreset }.count)")
        print("BENCH   names: \(available.map(\.name).joined(separator: ", "))")
    }

    @Test
    func benchmarkPerFrameWeights() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        entity.isAutomaticUpdateEnabled = false

        // Everything the model offers, all of which moves every frame.
        let ownKeys = entity.availableExpressions.map(\.key)
        // What a tracker hands over: the same keys plus the ARKit names this model
        // does not carry, which still have to be looked up and rejected.
        let trackedKeys = ownKeys + Self.perfectSyncNames.map { ExpressionKey.custom($0) }

        for (label, keys) in [("model keys", ownKeys), ("tracker keys", trackedKeys)] {
            print(String(format: "BENCH %@ (%d): %.1f µs/frame",
                         label, keys.count, microsecondsPerFrame(driving: entity, keys: keys)))
        }
    }

    /// Times the whole per-frame call an app makes: build the weights, hand them over,
    /// accumulate and write out what moved. Every frame moves every weight, which is
    /// what tracking does.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func microsecondsPerFrame(driving entity: VRMEntity, keys: [ExpressionKey], frames requested: Int = 2000) -> Double {
        let frames = ProcessInfo.processInfo.environment["VRMKIT_BENCH_FRAMES"].flatMap(Int.init) ?? requested
        var weights: [ExpressionKey: CGFloat] = [:]
        weights.reserveCapacity(keys.count)

        func frame(_ index: Int) {
            let base = CGFloat(index % 100) / 100
            for (offset, key) in keys.enumerated() {
                weights[key] = min(1, base + CGFloat(offset % 7) / 100)
            }
            entity.setExpressions(weights)
        }

        for index in 0..<(frames / 4) { frame(index) }
        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<frames { frame(index) }
        return (CFAbsoluteTimeGetCurrent() - start) * 1_000_000 / Double(frames)
    }
}
#endif
