#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What a load returns: the entity for the scene, and the runtime that drives it.
@Suite
@MainActor
struct VRMEntityTests {
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testLoadEntityReturnsTheEntityAndItsVRM(asset: VRMSampleAsset) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: asset.data).loadEntity()

        #expect(entity.document === entity.vrm.document)
        #expect(!entity.availableExpressions.isEmpty)
        #expect(entity.humanoid.node(for: .head) != nil)
    }

    @Test
    func testTheEntityDrivesExpressionsAndSprings() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        entity.setExpression(value: 1, for: .preset(.happy))
        #expect(entity.expression(for: .preset(.happy)) == 1)

        entity.springBoneConfiguration.externalForce = SIMD3<Float>(1, 0, 0)
        #expect(entity.springBoneConfiguration.externalForce == SIMD3<Float>(1, 0, 0))
        entity.resetSpringBones()
        entity.update(deltaTime: 1.0 / 60.0)

        entity.isAutomaticUpdateEnabled = false
        #expect(!entity.isAutomaticUpdateEnabled)
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

    @Test
    func testTheLoaderLoadsTheThumbnail() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let thumbnail = try VRMEntityLoader(withData: TestSupport.seedSanData).loadThumbnail()
        #expect(thumbnail.width > 0)
    }
}
#endif
