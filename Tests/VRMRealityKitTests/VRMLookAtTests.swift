#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// Aiming a loaded model's gaze, whichever way its version states the look-at: Alicia
/// turns eye bones through VRM 0.x curves, Seed-san weighs VRM 1.0 expressions.
@Suite
@MainActor
struct VRMLookAtTests {
    /// A world-space point `yaw` degrees to the model's own left of the gaze origin,
    /// which is where the eyes sit rather than where the head node does.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func target(yaw: Float, from entity: VRMEntity, offset: SIMD3<Float>) throws -> SIMD3<Float> {
        let head = try #require(entity.humanoid.node(for: .head))
        let origin = head.position(relativeTo: nil) + head.orientation(relativeTo: nil).act(offset)
        let forward = entity.vrm.forwardDirection
        let left = simd_cross(SIMD3<Float>(0, 1, 0), forward)
        let radians = yaw * .pi / 180
        return origin + (forward * cos(radians) + left * sin(radians)) * 10
    }

    /// How far a node turned from the rest rotation it loaded with, in degrees.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func turn(of node: Entity, from rest: simd_quatf) -> Float {
        (rest.conjugate * node.orientation).angle * 180 / .pi
    }

    /// A VRM 0.x bone look-at turns the eyes through the model's own curves: Alicia maps
    /// 30 degrees of gaze onto 10 degrees of eye.
    @Test
    func testAVRM0BoneLookAtTurnsTheEyesThroughTheModelsCurves() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let leftEye = try #require(entity.humanoid.node(for: .leftEye))
        let rightEye = try #require(entity.humanoid.node(for: .rightEye))
        let restLeft = leftEye.orientation
        let restRight = rightEye.orientation

        entity.lookAtTarget = .position(try Self.target(yaw: 15,
                                                        from: entity,
                                                        offset: SIMD3(0, 0.06, 0)))

        #expect(abs(Self.turn(of: leftEye, from: restLeft) - 5) < 0.05)
        #expect(abs(Self.turn(of: rightEye, from: restRight) - 5) < 0.05)
        // Half the gaze, half the turn: the curve this model states is a straight line.
        entity.lookAtTarget = .angles(yaw: 7.5, pitch: 0)
        #expect(abs(Self.turn(of: leftEye, from: restLeft) - 2.5) < 0.05)

        entity.lookAtTarget = nil
        #expect(Self.turn(of: leftEye, from: restLeft) < 1e-3)
        #expect(Self.turn(of: rightEye, from: restRight) < 1e-3)
    }

    /// A VRM 1.0 expression look-at weighs the look expressions instead, both eyes
    /// moving together through the outer map.
    @Test
    func testAVRM1ExpressionLookAtWeighsTheLookExpressions() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()

        // Seed-san maps 90 degrees of gaze onto a full weight.
        entity.lookAtTarget = .position(try Self.target(yaw: 45,
                                                        from: entity,
                                                        offset: SIMD3(0, 0.0776, 0.1007)))

        #expect(abs(entity.expression(for: .preset(.lookLeft)) - 0.5) < 0.01)
        #expect(entity.expression(for: .preset(.lookRight)) == 0)

        entity.lookAtTarget = .angles(yaw: 0, pitch: -90)
        #expect(entity.expression(for: .preset(.lookLeft)) == 0)
        #expect(entity.expression(for: .preset(.lookDown)) == 1)

        entity.lookAtTarget = nil
        #expect(entity.expression(for: .preset(.lookDown)) == 0)
    }

    /// The gaze follows the target as the model moves, which is what an update is for.
    @Test
    func testTheGazeFollowsAsTheModelTurns() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let entity = try await VRMEntityLoader(withData: TestSupport.aliciaSolidData).loadEntity()
        let leftEye = try #require(entity.humanoid.node(for: .leftEye))
        let rest = leftEye.orientation

        entity.lookAtTarget = .position(try Self.target(yaw: 15,
                                                        from: entity,
                                                        offset: SIMD3(0, 0.06, 0)))
        let aimed = Self.turn(of: leftEye, from: rest)

        // Turning the model onto the target leaves the eyes nothing to make up.
        entity.orientation = simd_quatf(angle: 15 * .pi / 180, axis: SIMD3(0, 1, 0))
        entity.update(deltaTime: 1.0 / 60.0)

        #expect(abs(aimed - 5) < 0.05)
        #expect(Self.turn(of: leftEye, from: rest) < 0.05)
    }
}
#endif
