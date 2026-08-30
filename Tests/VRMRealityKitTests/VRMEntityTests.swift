#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What a load returns: the entity for the scene, the runtime that drives it,
/// and the picture the model states for itself.
@Suite
@MainActor
struct VRMEntityTests {
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testLoadEntityReturnsTheEntityItsVRMAndItsThumbnail(asset: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: asset.data)
        let entity = try await loader.loadEntity()

        #expect(entity.document === entity.vrm.document)
        #expect(!entity.availableExpressions.isEmpty)
        #expect(entity.humanoid.node(for: .head) != nil)
        #expect(try loader.loadThumbnail().width > 0)
    }

    /// A VRM 1.0 model states its presets under the names 1.0 spells them with,
    /// unlike a 0.x one, which names its groups whatever it likes.
    @Test
    func testAvailableExpressionsCarryTheNamesTheModelStates() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        let expressions = entity.availableExpressions
        #expect(expressions.contains(ExpressionInfo(key: .preset(.happy), name: "happy")))
        for expression in expressions {
            guard let preset = expression.preset else { continue }
            #expect(expression.name == preset.rawValue)
        }
    }
}
#endif
