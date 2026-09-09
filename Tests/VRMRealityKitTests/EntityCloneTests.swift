#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What `Entity.clone(recursive:)` copies. RealityKit builds a clone through
/// `init()`, so it renders what the original rendered and carries none of the
/// runtime behind it: every API that would drive the model has to say so rather
/// than silently doing nothing.
@Suite
@MainActor
struct EntityCloneTests {
    /// A clone reads its metadata off the document it carries, and refuses the
    /// playback that metadata describes.
    @Test
    func testACloneOfAGLTFEntityCannotBeAnimated() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await TestSupport.loadEntity(.animatedTriangle)
        let clone = entity.clone(recursive: true)

        #expect(entity.hasRuntimeBindings)
        #expect(!clone.hasRuntimeBindings)
        #expect(clone.animations.count == entity.animations.count)
        #expect(throws: VRMError.self) { try clone.playAnimation(at: 0) }
    }

    /// The VRM rides on the entity as a component, so a clone can still be asked
    /// what model it came from instead of trapping. Nothing that drives that
    /// model comes with it.
    @Test
    func testACloneOfAVRMEntityIsInertButKeepsItsVRM() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        let clone = vrmEntity.clone(recursive: true)

        guard case .v1 = clone.vrm else {
            Issue.record("The clone lost the VRM it was copied from")
            return
        }
        #expect(vrmEntity.humanoid.node(for: .neck) != nil)
        #expect(clone.humanoid.node(for: .neck) == nil)
        // Material indices scope the runtime material setters, so a clone answers
        // none rather than indices those setters could not act on.
        #expect(!vrmEntity.materialIndices(under: vrmEntity).isEmpty)
        #expect(clone.materialIndices(under: clone).isEmpty)
        #expect(vrmEntity.materialIndices(under: clone).isEmpty)
        #expect(throws: VRMError.self) {
            try clone.playAnimation(try VRMAnimation(data: VRMASampleFixture.standard()))
        }
        // The update system reaches the clone too, so updating it has to stay harmless.
        clone.update(deltaTime: 1.0 / 60.0)
    }

    /// A copy with its own material parameters starts from the original's and then
    /// takes lighting on its own, each holding parameter rows of its own.
    @Test
    func testACloneWithOwnMaterialParametersIsLitOnItsOwn() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), TestSupport.isMToonRenderingAvailable else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                                  shaders: TestSupport.noOutlineShaders).loadEntity()
        let original = SIMD3<Float>(1, 0, 0)
        vrmEntity.setMToonLightDirection(original)
        let copy = vrmEntity.cloneWithOwnMaterialParameters()
        let index = try #require(vrmEntity.materialIndices(under: vrmEntity).sorted().first {
            vrmEntity.mtoonParameters(forMaterialIndex: $0) != nil
        })

        #expect(!copy.hasRuntimeBindings)
        #expect(copy.materialIndices(under: copy) == vrmEntity.materialIndices(under: vrmEntity))
        #expect(copy.mtoonParameters(forMaterialIndex: index)?.lightDirection == original)

        let relit = SIMD3<Float>(0, 0, 1)
        copy.setMToonLightDirection(relit)
        #expect(copy.mtoonParameters(forMaterialIndex: index)?.lightDirection == relit)
        #expect(vrmEntity.mtoonParameters(forMaterialIndex: index)?.lightDirection == original)
        vrmEntity.setMToonLightColor(SIMD3(0.5, 0.5, 0.5))
        #expect(copy.mtoonParameters(forMaterialIndex: index)?.lightColor == SIMD4(1, 1, 1, 1))

#if !os(visionOS)
        // The rows are a texture of its own, installed on its own materials, and writing to
        // them leaves the original's where they were. Compared as the states hold them:
        // a material hands back a new resource wrapper on every read.
        let ownRows = try #require(copy.mtoonState(forMaterialIndex: index)?.parameterTexture)
        let sourceRows = try #require(vrmEntity.mtoonState(forMaterialIndex: index)?.parameterTexture)
        #expect(ownRows !== sourceRows)
        #expect(copy.mtoonState(forMaterialIndex: index)?.updatesMaterialsOnFlush == false)
        let writesBefore = sourceRows.writeCount
        copy.setMToonLightDirection(SIMD3<Float>(0, 1, 0))
        #expect(sourceRows.writeCount == writesBefore)
        #expect(ownRows.writeCount > 0)
#endif
    }

    /// A joint posed since the last update reaches the copy's meshes: the copy is drawn
    /// as its joints describe, not as the last solve left them.
    @Test
    func testACloneWithOwnMaterialParametersCarriesThePoseItsJointsDescribe() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
        vrmEntity.update(deltaTime: 1.0 / 60.0)
        let solved = TestSupport.jointRotations(in: vrmEntity)

        // Posed the way a caller drives a humanoid bone, without an update to solve it.
        let head = try #require(vrmEntity.humanoid.node(for: .head))
        head.transform.rotation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        vrmEntity.invalidateSkinPose()
        #expect(TestSupport.jointRotations(in: vrmEntity) == solved)

        let copy = vrmEntity.cloneWithOwnMaterialParameters()
        #expect(TestSupport.jointRotations(in: copy) != solved)
        #expect(TestSupport.jointRotations(in: copy) == TestSupport.jointRotations(in: vrmEntity))
    }

    /// The copy keeps what the original's expressions had written to its materials
    /// at the call, however the original moves on.
    @Test
    func testACloneWithOwnMaterialParametersKeepsWhatExpressionsHadWritten() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), TestSupport.isMToonRenderingAvailable else { return }
        let vrmEntity = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                                  shaders: TestSupport.noOutlineShaders).loadEntity()
        // Seed-san's happy expression shifts the UV of material 11.
        vrmEntity.setExpression(value: 1, for: .preset(.happy))
        let copy = vrmEntity.cloneWithOwnMaterialParameters()
        vrmEntity.setExpression(value: 0, for: .preset(.happy))

        #expect(try TestSupport.mtoonParameters(in: vrmEntity, materialIndex: 11).uvTransform.z.isApproximatelyEqual(to: 0))
        #expect(try TestSupport.mtoonParameters(in: copy, materialIndex: 11).uvTransform.z.isApproximatelyEqual(to: 0.25))
    }
}
#endif
