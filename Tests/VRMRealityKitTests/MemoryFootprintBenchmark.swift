#if canImport(RealityKit)
import Darwin
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Reports process resident-size deltas for representative avatar loads. It is opt-in because
/// allocator caches and simulator services make memory numbers unsuitable for normal assertions.
///
///     VRMKIT_BENCH=1 swift test -c release --filter MemoryFootprintBenchmark
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VRMKIT_BENCH"] == "1"), .serialized)
@MainActor
struct MemoryFootprintBenchmark {
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                            / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    @Test
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    func benchmarkRepresentativeAvatarMemory() async throws {
        struct Sample {
            let name: String
            let load: () async throws -> VRMEntity
            let playback: Bool
        }
        let samples = [
            Sample(name: "VRM0 Alicia", load: {
                try await VRMEntityLoader(withData: VRMSampleAsset.aliciaSolid.data,
                                          shaders: []).loadEntity()
            }, playback: false),
            Sample(name: "VRM1 Seed-san MToon", load: {
                try await VRMEntityLoader(withData: VRMSampleAsset.seedSan.data).loadEntity()
            }, playback: false),
            Sample(name: "VRMA on VRM1", load: {
                let entity = try await VRMEntityLoader(withData: VRMSampleAsset.seedSan.data,
                                                       shaders: []).loadEntity()
                _ = try entity.playAnimation(try VRMAnimation(data: VRMASampleFixture.standard()),
                                             loops: true)
                return entity
            }, playback: true)
        ]

        for sample in samples {
            let baseline = residentBytes()
            var entities: [VRMEntity] = []
            for _ in 0..<3 {
                entities.append(try await sample.load())
            }
            for entity in entities where sample.playback {
                entity.updateAnimations(deltaTime: 1.0 / 60.0)
            }
            let peak = residentBytes()
            entities.removeAll()
            await Task.yield()
            let afterUnload = residentBytes()
            print(String(format: "MEM %@: baseline=%llu peak=%llu delta=%.1f MiB afterUnload=%llu retained=%.1f MiB",
                         sample.name,
                         baseline,
                         peak,
                         Double(peak - baseline) / 1_048_576,
                         afterUnload,
                         Double(afterUnload > baseline ? afterUnload - baseline : 0) / 1_048_576))
        }
    }
}
#endif
